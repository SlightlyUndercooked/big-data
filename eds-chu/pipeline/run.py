"""
Point d'entrée du pipeline EDS-CHU.

    cd eds-chu/ && python -m pipeline.run

Action :
    1. Découvre automatiquement les dates disponibles dans SOURCE_DIR
    2. Copie et pseudonymise les nouvelles dates vers le lake (step0)
    3. Charge les nouvelles dates en Bronze (step1), incrémental
    4. Reconstruit Silver depuis tout le Bronze (step2)
    5. Recrée les vues Gold (step3)
    6. Applique le cloisonnement des accès Gold (step4)

Le pipeline est conçu pour être rejoué quotidiennement (cron).

Traçabilité : chaque run Bronze est enregistré dans meta.pipeline_runs
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
from .step4_grants import build_grants

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
log = logging.getLogger(__name__)


def _discover_source_dates() -> list[str]:
    """Trouve toutes les dates disponibles, toutes tables confondues.

    Union des dates présentes dans patients/, sejours/, diagnostics/,
    monitoring/ et actes/ : les tables ne couvrent pas forcément les mêmes périodes
    (ex: patients déposé en photo complète sur les derniers jours seulement,
    alors que l'historique d'activité remonte plus loin). Une date est
    traitée dès qu'au moins une table a des données pour elle ; les fichiers
    manquants pour les autres tables sont simplement ignorés (step0/step1).
    Les dates sont triées pour garantir un chargement chronologique.
    """
    tables = ("patients", "sejours", "diagnostics", "monitoring", "actes")
    dates: set[str] = set()
    for table in tables:
        table_dir = config.SOURCE_DIR / table
        if table_dir.exists():
            dates.update(p.name for p in table_dir.iterdir() if p.is_dir())
    if not dates:
        raise FileNotFoundError(
            f"Aucune date trouvée dans {config.SOURCE_DIR} (dossiers {tables})"
        )
    return sorted(dates)


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

    init_bronze(ch)

    # Les référentiels (services, CIM-10) sont déposés une seule fois par le CHU.
    # copy_referentiels copie vers le lake, load_referentiels insère dans Bronze.
    # Les deux opérations sont idempotentes : rejouer ne double pas les données.
    copy_referentiels()
    load_referentiels(ch)

    dates = _discover_source_dates()
    log.info(f"Dates source : {dates}")

    new_dates = []
    for date_str in dates:
        # Step 0 : pseudonymisation + copie vers le lake.
        # Idempotent : si les fichiers lake existent déjà, rien n'est refait.
        counts = copy_date_to_lake(date_str)
        if any(v > 0 for v in counts.values()):
            log.info(f"Lake {date_str} : {counts}")

        # Step 1 : chargement Bronze.
        # Vérifie meta.pipeline_runs → saute la date si déjà en 'success'.
        loaded = load_bronze(ch, date_str)
        if loaded:
            new_dates.append(date_str)

    if new_dates:
        log.info(f"Nouvelles dates chargées en Bronze : {new_dates}")
    else:
        log.info("Aucune nouvelle date en Bronze.")

    # Silver / Gold / grants : reconstruction totale à chaque run.
    # Bronze seul est incrémental (meta.pipeline_runs).
    build_silver(ch)
    build_gold(ch)
    build_grants(ch)

    log.info("=" * 60)
    log.info("Pipeline EDS-CHU — terminé avec succès")
    log.info("=" * 60)


if __name__ == "__main__":
    try:
        run()
    except Exception as e:
        log.error(f"Erreur pipeline : {e}")
        sys.exit(1)
