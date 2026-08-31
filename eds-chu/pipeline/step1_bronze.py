"""
ÉTAPE 1 — CHARGEMENT BRONZE

Rôle : lire les fichiers du lake et les insérer dans les tables Bronze de ClickHouse.

Principe incrémental : on consulte meta.pipeline_runs pour ne jamais insérer
deux fois la même date. Si la date est déjà marquée 'success', on la saute.

Formats gérés :
  - CSV (patients, séjours, référentiels) : lus avec le module csv standard
  - JSON imbriqué (diagnostics) : dépliés en Python avant insertion
  - Parquet (monitoring) : lus avec PyArrow, inséré via insert_arrow (efficace)

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
    """Lit un fichier .sql et exécute chaque instruction séparée par ';'."""
    sql = _sql_path(filename).read_text()
    for stmt in sql.split(";"):
        stmt = stmt.strip()
        # Sauter les blocs vides ou purement commentaires
        lines = [l for l in stmt.splitlines() if not l.strip().startswith("--")]
        clean = "\n".join(lines).strip()
        if clean:
            ch.command(clean)


def init_bronze(ch) -> None:
    """Crée les bases et tables Bronze si elles n'existent pas."""
    log.info("Initialisation du schéma Bronze et Meta...")
    _exec_sql_file(ch, "bronze.sql")


def _already_loaded(ch, date_str: str) -> bool:
    """Vérifie si cette date a déjà été chargée en Bronze avec succès."""
    result = ch.query(
        "SELECT count() FROM meta.pipeline_runs "
        "WHERE layer = 'bronze' AND source_date = {d:String} AND status = 'success'",
        parameters={"d": date_str},
    )
    return result.result_rows[0][0] > 0


def _record_run(ch, date_str: str, status: str, rows: int, error: str = "") -> None:
    """Enregistre le résultat d'un run dans la table de traçabilité."""
    ch.insert(
        "meta.pipeline_runs",
        [[
            "bronze",
            date_str,
            status,
            datetime.now(),         # started_at (approximation)
            datetime.now(),         # finished_at
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

    # Dépliage du JSON imbriqué : 1 ligne par (stay_id, code_cim10)
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

    table = pq.read_table(lake_file)

    # Ajout de la colonne _source_date pour la traçabilité
    src_date_col = pa.array([src_date] * table.num_rows, type=pa.date32())
    table = table.append_column("_source_date", src_date_col)

    # insert_arrow est la méthode la plus efficace pour les gros volumes Parquet
    ch.insert_arrow("bronze.monitoring", table)
    return table.num_rows


def _load_referentiels(ch) -> None:
    """Charge les référentiels (idempotent grâce à ReplacingMergeTree)."""
    ref_dir = config.LAKE_DIR / "referentiels"

    # Services
    rows_svc = []
    with open(ref_dir / "services.csv", newline="") as f:
        for row in csv.DictReader(f):
            rows_svc.append([row["service_code"], row["service_label"]])
    ch.insert("bronze.services", rows_svc, column_names=["service_code", "service_label"])

    # CIM-10
    rows_cim = []
    with open(ref_dir / "cim10.csv", newline="") as f:
        for row in csv.DictReader(f):
            rows_cim.append([row["code_cim10"], row["libelle"]])
    ch.insert("bronze.cim10", rows_cim, column_names=["code_cim10", "libelle"])


def load_bronze(ch, date_str: str) -> bool:
    """
    Charge toutes les sources d'une date dans Bronze.
    Retourne True si de nouvelles données ont été chargées, False si déjà fait.
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

        _record_run(ch, date_str, "success", total_rows)
        log.info(f"Bronze {date_str} : {total_rows} lignes chargées.")
        return True

    except Exception as exc:
        _record_run(ch, date_str, "error", total_rows, str(exc))
        log.error(f"Bronze {date_str} : erreur — {exc}")
        raise


def load_referentiels(ch) -> None:
    """Charge les référentiels (services, CIM-10). Idempotent."""
    if _already_loaded(ch, "referentiels"):
        log.info("Référentiels déjà chargés, ignorés.")
        return
    log.info("Chargement des référentiels...")
    _load_referentiels(ch)
    _record_run(ch, "referentiels", "success", 0)
