"""
ÉTAPE 1 — CHARGEMENT BRONZE

Lit le lake et insère dans ClickHouse. Incrémental via meta.pipeline_runs :
une date déjà en 'success' est sautée.

Avant chaque tentative, _cleanup_date supprime les lignes de cette
_source_date. Un crash entre deux inserts (patients / séjours /
diagnostics / monitoring) ne laisse donc pas de partiel qui serait
dupliqué au retry — MergeTree ne déduplique pas.

Le typage Python (str → datetime / int) est un premier filet : une
valeur illisible fait échouer l'insert plutôt que d'entrer en base.

Formats : CSV, JSON imbriqué (diagnostics dépliés en 1 ligne / code),
Parquet via insert_arrow.

Bronze ne filtre rien. Les anomalies restent en base pour audit ;
Silver applique les contrôles qualité.
"""
import csv
import json
import logging
from datetime import date, datetime

import pyarrow as pa
import pyarrow.parquet as pq

from . import config

log = logging.getLogger(__name__)


def init_bronze(ch) -> None:
    """Crée bases et tables Bronze (IF NOT EXISTS)."""
    log.info("Initialisation du schéma Bronze et Meta...")
    config.exec_sql_file(ch, "bronze.sql")


# Référentiels exclus : pas de _source_date, vidés à part.
_BRONZE_TABLES_PAR_DATE = (
    "bronze.patients",
    "bronze.sejours",
    "bronze.diagnostics",
    "bronze.monitoring",
)


def _cleanup_date(ch, date_str: str) -> None:
    """Supprime les lignes Bronze de cette _source_date avant réinsert.

    mutations_sync=2 : attend que le DELETE soit visible, sinon le
    réinsert pourrait coexister avec des lignes encore marquées.
    """
    for table in _BRONZE_TABLES_PAR_DATE:
        ch.command(
            f"DELETE FROM {table} WHERE _source_date = {{d:Date}}",
            parameters={"d": date_str},
            settings={"mutations_sync": 2},
        )


def _cleanup_referentiels(ch) -> None:
    """TRUNCATE des référentiels (pas de _source_date) avant réinsert."""
    ch.command("TRUNCATE TABLE IF EXISTS bronze.services")
    ch.command("TRUNCATE TABLE IF EXISTS bronze.cim10")


def _already_loaded(ch, date_str: str) -> bool:
    """True si meta.pipeline_runs a déjà un run Bronze 'success' pour cette date."""
    result = ch.query(
        "SELECT count() FROM meta.pipeline_runs "
        "WHERE layer = 'bronze' AND source_date = {d:String} AND status = 'success'",
        parameters={"d": date_str},
    )
    return result.result_rows[0][0] > 0


def _record_run(ch, date_str: str, status: str, rows: int, error: str = "") -> None:
    """Écrit le résultat du run. Un statut 'error' n'empêche pas le retry."""
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
    if not lake_file.exists():
        return 0
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
    if not lake_file.exists():
        return 0
    rows = []
    src_date = date.fromisoformat(date_str)

    with open(lake_file, newline="") as f:
        for row in csv.DictReader(f):
            # Chaîne vide = séjour en cours → NULL. On n'écarte rien ici.
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
    if not lake_file.exists():
        return 0
    rows = []
    src_date = date.fromisoformat(date_str)

    with open(lake_file) as f:
        data = json.load(f)

    # JSON imbriqué → 1 ligne par (stay_id, code_cim10, type).
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
    if not lake_file.exists():
        return 0
    src_date = date.fromisoformat(date_str)

    table = pq.read_table(lake_file)
    src_date_col = pa.array([src_date] * table.num_rows, type=pa.date32())
    table = table.append_column("_source_date", src_date_col)
    ch.insert_arrow("bronze.monitoring", table)
    return table.num_rows


def _load_referentiels(ch) -> None:
    """Charge services et CIM-10 (ReplacingMergeTree côté schéma)."""
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
    """Charge les 4 sources d'une date. True si insertion, False si déjà fait."""
    if _already_loaded(ch, date_str):
        log.info(f"Bronze {date_str} : déjà chargé, ignoré.")
        return False

    log.info(f"Bronze {date_str} : chargement en cours...")
    _cleanup_date(ch, date_str)
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
    """Charge services et CIM-10. source_date sentinelle : 'referentiels'."""
    if _already_loaded(ch, "referentiels"):
        log.info("Référentiels déjà chargés, ignorés.")
        return
    log.info("Chargement des référentiels...")
    _cleanup_referentiels(ch)
    try:
        _load_referentiels(ch)
        _record_run(ch, "referentiels", "success", 0)
    except Exception as exc:
        _record_run(ch, "referentiels", "error", 0, str(exc))
        log.error(f"Référentiels : erreur — {exc}")
        raise
