"""
ÉTAPE 2 — COUCHE SILVER

Envoie sql/silver.sql à ClickHouse. Toute la logique de qualité est dans
ce SQL, pas ici. Silver est reconstruite entièrement à chaque run
(CREATE OR REPLACE) ; l'incrémentalité est gérée en Bronze.
"""
import logging

from . import config

log = logging.getLogger(__name__)


def build_silver(ch) -> None:
    """Reconstruit Silver depuis Bronze via silver.sql."""
    log.info("Construction de la couche Silver...")
    config.exec_sql_file(ch, "silver.sql")
    log.info("Silver prête.")
