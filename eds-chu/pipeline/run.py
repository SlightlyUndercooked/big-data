"""
ORCHESTRATEUR — Point d'entrée du pipeline EDS-CHU

Usage :
    cd eds-chu/
    python -m pipeline.run

Comportement :
    1. Découvre automatiquement les dates disponibles dans SOURCE_DIR
    2. Copie et pseudonymise les nouvelles dates vers le lake (step0)
    3. Charge les nouvelles dates en Bronze (step1) — incrémental
    4. Reconstruit Silver depuis tout le Bronze (step2)
    5. Recrée les vues Gold (step3)

Le pipeline est conçu pour être rejoué quotidiennement (cron).
Chaque run est idempotent : relancer deux fois le même jour ne duplique pas.

Traçabilité : chaque run Bronze est enregistré dans meta.pipeline_runs.
En cas d'erreur, le statut 'error' est enregistré et le run s'arrête.
"""
import logging
import sys

import clickhouse_connect

from . import config
from .step0_lake import copy_date_to_lake, copy_referentiels
from .step1_bronze import init_bronze, load_bronze, load_referentiels
from .step2_silver import build_silver
from .step3_gold import build_gold

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
log = logging.getLogger(__name__)


def _discover_source_dates() -> list[str]:
    """Trouve toutes les dates disponibles dans SOURCE_DIR/patients/."""
    patients_dir = config.SOURCE_DIR / "patients"
    if not patients_dir.exists():
        raise FileNotFoundError(f"Dossier source introuvable : {patients_dir}")
    return sorted(p.name for p in patients_dir.iterdir() if p.is_dir())


def _get_client():
    return clickhouse_connect.get_client(
        host=config.CLICKHOUSE_HOST,
        port=config.CLICKHOUSE_PORT,
        username=config.CLICKHOUSE_USER,
        password=config.CLICKHOUSE_PASSWORD,
    )


def run() -> None:
    log.info("=" * 60)
    log.info("Pipeline EDS-CHU — démarrage")
    log.info(f"Source : {config.SOURCE_DIR}")
    log.info(f"Lake   : {config.LAKE_DIR}")
    log.info("=" * 60)

    ch = _get_client()

    # Initialisation du schéma Bronze (idempotent)
    init_bronze(ch)

    # Référentiels (services, CIM-10)
    copy_referentiels()
    load_referentiels(ch)

    # Traitement incrémental par date
    dates = _discover_source_dates()
    log.info(f"Dates source : {dates}")

    new_dates = []
    for date_str in dates:
        # Step 0 : copie + pseudonymisation vers le lake (idempotent)
        counts = copy_date_to_lake(date_str)
        if any(v > 0 for v in counts.values()):
            log.info(f"Lake {date_str} : {counts}")

        # Step 1 : chargement Bronze (saute si déjà fait)
        loaded = load_bronze(ch, date_str)
        if loaded:
            new_dates.append(date_str)

    if not new_dates:
        log.info("Aucune nouvelle date. Pipeline terminé sans modification.")
        return

    log.info(f"Nouvelles dates chargées en Bronze : {new_dates}")

    # Step 2 : reconstruction Silver depuis tout le Bronze
    build_silver(ch)

    # Step 3 : vues Gold (idempotent)
    build_gold(ch)

    log.info("=" * 60)
    log.info("Pipeline EDS-CHU — terminé avec succès")
    log.info("=" * 60)


if __name__ == "__main__":
    try:
        run()
    except Exception as e:
        log.error(f"Erreur pipeline : {e}")
        sys.exit(1)
