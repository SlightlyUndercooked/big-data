"""
ÉTAPE 1 — CHARGEMENT BRONZE

Rôle : lire les fichiers du lake et les insérer dans les tables Bronze de ClickHouse.

Principe incrémental : on consulte meta.pipeline_runs pour ne jamais insérer
deux fois la même date. Si la date est déjà marquée 'success', on la saute.

Typage comme premier filet de qualité :
  Toutes les sources arrivent en texte brut (CSV = tout string, JSON = tout string).
  Python convertit les valeurs avant insertion : str → datetime, str → int, etc.
  Si une valeur n'est pas parseable (ex: admission_ts invalide), l'insertion plante
  immédiatement avec une erreur explicite. C'est voulu : mieux vaut échouer tôt
  sur une donnée corrompue que la laisser entrer silencieusement dans la base.

Formats gérés :
  - CSV (patients, séjours, référentiels) : lus avec le module csv standard
  - JSON imbriqué (diagnostics) : dépliés en Python avant insertion
    (double boucle séjour → diagnostics → 1 ligne par code CIM-10)
  - Parquet (monitoring) : lu avec PyArrow, inséré via insert_arrow
    (protocole binaire natif ClickHouse, plus rapide que les listes Python)

Principe fondamental : Bronze ne filtre rien.
  Les séjours incohérents (discharge < admission) et les séjours en cours
  (discharge NULL) sont tous insérés tels quels. Filtrer en Bronze ferait
  perdre la traçabilité des anomalies. C'est Silver qui applique les règles métier.
"""
import csv
import json
import logging
from datetime import date, datetime
from pathlib import Path

import pyarrow as pa
import pyarrow.parquet as pq

from . import config

log = logging.getLogger(__name__)


def _sql_path(filename: str) -> Path:
    return Path(__file__).parent.parent / "sql" / filename


def _exec_sql_file(ch, filename: str) -> None:
    """Lit un fichier .sql et exécute chaque instruction séparée par ';'.

    Les commentaires sont supprimés AVANT le split pour éviter qu'un ';'
    dans un commentaire (ex: 'region_code ; il est...') soit interprété
    à tort comme un séparateur d'instruction SQL.
    """
    sql = _sql_path(filename).read_text()
    no_comments = "\n".join(
        l for l in sql.splitlines() if not l.strip().startswith("--")
    )
    for stmt in no_comments.split(";"):
        clean = stmt.strip()
        if clean:
            ch.command(clean)


def init_bronze(ch) -> None:
    """Crée les bases et tables Bronze si elles n'existent pas.

    Utilise IF NOT EXISTS partout → idempotent : rejouer n'écrase rien.
    """
    log.info("Initialisation du schéma Bronze et Meta...")
    _exec_sql_file(ch, "bronze.sql")


def _already_loaded(ch, date_str: str) -> bool:
    """Vérifie dans meta.pipeline_runs si cette date a déjà été chargée avec succès.

    C'est le mécanisme central de l'incrémentalité : on ne consulte pas
    les tables Bronze elles-mêmes (requête coûteuse) mais la table de traçabilité,
    qui est légère et indexée sur (layer, source_date).
    """
    result = ch.query(
        "SELECT count() FROM meta.pipeline_runs "
        "WHERE layer = 'bronze' AND source_date = {d:String} AND status = 'success'",
        parameters={"d": date_str},
    )
    return result.result_rows[0][0] > 0


def _record_run(ch, date_str: str, status: str, rows: int, error: str = "") -> None:
    """Enregistre le résultat d'un run dans meta.pipeline_runs.

    En cas d'erreur, le statut 'error' est enregistré (pas de silencing).
    Lors du prochain run, _already_loaded retournera False pour cette date
    (on ne cherche que les status='success'), donc le pipeline retentera.
    """
    ch.insert(
        "meta.pipeline_runs",
        [[
            "bronze",
            date_str,
            status,
            datetime.now(),  # started_at
            datetime.now(),  # finished_at
            rows,
            error or None,
        ]],
        column_names=[
            "layer", "source_date", "status",
            "started_at", "finished_at", "rows_processed", "error_msg",
        ],
    )


def _load_patients(ch, date_str: str) -> int:
    lake_file = config.LAKE_DIR / "patients" / date_str / "patients.csv"
    rows = []
    # On convertit date_str en objet date Python pour que ClickHouse reçoive
    # le bon type (Date32) et non une chaîne à parser côté serveur.
    src_date = date.fromisoformat(date_str)

    with open(lake_file, newline="") as f:
        for row in csv.DictReader(f):
            rows.append([
                row["patient_pseudo"],
                int(row["birth_year"]),
                row["sex"],
                row["region_code"],
                src_date,
            ])

    ch.insert(
        "bronze.patients",
        rows,
        column_names=["patient_pseudo", "birth_year", "sex", "region_code", "_source_date"],
    )
    return len(rows)


def _load_sejours(ch, date_str: str) -> int:
    lake_file = config.LAKE_DIR / "sejours" / date_str / "sejours.csv"
    rows = []
    src_date = date.fromisoformat(date_str)

    with open(lake_file, newline="") as f:
        for row in csv.DictReader(f):
            # discharge_ts peut être vide (séjour en cours) → None = NULL en SQL.
            # On ne filtre pas ici : Bronze conserve toutes les données brutes,
            # y compris les séjours en cours et les incohérences temporelles.
            # C'est Silver qui appliquera les règles de qualité.
            discharge = (
                datetime.fromisoformat(row["discharge_ts"])
                if row["discharge_ts"]
                else None
            )
            rows.append([
                row["stay_id"],
                row["patient_pseudo"],
                row["service_code"],
                datetime.fromisoformat(row["admission_ts"]),
                discharge,
                row["admission_mode"],
                row["discharge_mode"],
                src_date,
            ])

    ch.insert(
        "bronze.sejours",
        rows,
        column_names=[
            "stay_id", "patient_pseudo", "service_code",
            "admission_ts", "discharge_ts",
            "admission_mode", "discharge_mode",
            "_source_date",
        ],
    )
    return len(rows)


def _load_diagnostics(ch, date_str: str) -> int:
    lake_file = config.LAKE_DIR / "diagnostics" / date_str / "diagnostics.json"
    rows = []
    src_date = date.fromisoformat(date_str)

    with open(lake_file) as f:
        data = json.load(f)

    # Dépliage du JSON imbriqué : structure source = liste d'objets
    # {"stay_id": "S001", "diagnostics": [{"code_cim10": "I10", "type": "principal"}, ...]}
    # On produit 1 ligne par (stay_id, code_cim10) pour un grain analytique plat,
    # directement requêtable en SQL sans dépiler un tableau à chaque fois.
    for entry in data:
        for diag in entry.get("diagnostics", []):
            rows.append([
                entry["stay_id"],
                diag["code_cim10"],
                diag["type"],   # 'principal' | 'associe'
                src_date,
            ])

    ch.insert(
        "bronze.diagnostics",
        rows,
        column_names=["stay_id", "code_cim10", "type_diag", "_source_date"],
    )
    return len(rows)


def _load_monitoring(ch, date_str: str) -> int:
    lake_file = config.LAKE_DIR / "monitoring" / date_str / "monitoring.parquet"
    src_date = date.fromisoformat(date_str)

    # PyArrow lit le Parquet nativement en mémoire sous forme de Table Arrow.
    table = pq.read_table(lake_file)

    # On ajoute _source_date directement dans la Table Arrow avant insertion.
    # Plus efficace que de passer par Python ligne par ligne.
    src_date_col = pa.array([src_date] * table.num_rows, type=pa.date32())
    table = table.append_column("_source_date", src_date_col)

    # insert_arrow envoie la Table Arrow directement à ClickHouse via le protocole
    # binaire natif — c'est la méthode la plus rapide pour les gros volumes Parquet,
    # sans conversion intermédiaire vers des listes Python.
    ch.insert_arrow("bronze.monitoring", table)
    return table.num_rows


def _load_referentiels(ch) -> None:
    """Charge les référentiels services et CIM-10 dans Bronze.

    Idempotent grâce au moteur ReplacingMergeTree des tables cibles :
    si on insère deux fois les mêmes codes, ClickHouse ne garde qu'une version
    lors du prochain merge (et Silver force la dédup avec FINAL).
    """
    ref_dir = config.LAKE_DIR / "referentiels"

    rows_svc = []
    with open(ref_dir / "services.csv", newline="") as f:
        for row in csv.DictReader(f):
            rows_svc.append([row["service_code"], row["service_label"]])
    ch.insert("bronze.services", rows_svc, column_names=["service_code", "service_label"])

    rows_cim = []
    with open(ref_dir / "cim10.csv", newline="") as f:
        for row in csv.DictReader(f):
            rows_cim.append([row["code_cim10"], row["libelle"]])
    ch.insert("bronze.cim10", rows_cim, column_names=["code_cim10", "libelle"])


def load_bronze(ch, date_str: str) -> bool:
    """Charge toutes les sources d'une date dans Bronze.

    Logique incrémentale : si cette date est déjà en 'success' dans
    meta.pipeline_runs, on ne fait rien. Sinon, on charge les 4 sources
    dans l'ordre, et on enregistre le résultat (succès ou erreur).

    Retourne True si de nouvelles données ont été chargées, False sinon.
    """
    if _already_loaded(ch, date_str):
        log.info(f"Bronze {date_str} : déjà chargé, ignoré.")
        return False

    log.info(f"Bronze {date_str} : chargement en cours...")
    total_rows = 0

    try:
        n = _load_patients(ch, date_str)
        log.info(f"  patients    : {n} lignes")
        total_rows += n

        n = _load_sejours(ch, date_str)
        log.info(f"  sejours     : {n} lignes")
        total_rows += n

        n = _load_diagnostics(ch, date_str)
        log.info(f"  diagnostics : {n} lignes")
        total_rows += n

        n = _load_monitoring(ch, date_str)
        log.info(f"  monitoring  : {n} lignes")
        total_rows += n

        # On enregistre le succès APRÈS toutes les insertions : si une étape
        # échoue à mi-chemin, on ne marque pas la date comme traitée,
        # ce qui forcera un retry complet au prochain run.
        _record_run(ch, date_str, "success", total_rows)
        log.info(f"Bronze {date_str} : {total_rows} lignes chargées.")
        return True

    except Exception as exc:
        # On enregistre l'erreur pour l'audit trail, puis on relève l'exception
        # pour que l'orchestrateur (run.py) s'arrête et signale l'échec.
        _record_run(ch, date_str, "error", total_rows, str(exc))
        log.error(f"Bronze {date_str} : erreur — {exc}")
        raise


def load_referentiels(ch) -> None:
    """Charge les référentiels (services, CIM-10). Idempotent.

    On utilise 'referentiels' comme source_date dans meta.pipeline_runs
    (valeur sentinelle) pour réutiliser le même mécanisme de traçabilité
    que pour les dates quotidiennes.
    """
    if _already_loaded(ch, "referentiels"):
        log.info("Référentiels déjà chargés, ignorés.")
        return
    log.info("Chargement des référentiels...")
    _load_referentiels(ch)
    _record_run(ch, "referentiels", "success", 0)
