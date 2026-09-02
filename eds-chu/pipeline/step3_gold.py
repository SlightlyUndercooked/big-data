"""
ÉTAPE 3 — COUCHE GOLD

Crée les vues des deux bases gold_pilotage et gold_recherche
(sql/gold_*.sql). Ce sont des VIEWS sur Silver, pas des tables.

Les droits ClickHouse sont appliqués ensuite (step4). Les vues sont
en SQL SECURITY DEFINER : un compte Gold peut les lire sans droit
sur silver.
"""
import logging

from . import config

log = logging.getLogger(__name__)


def build_gold(ch) -> None:
    """Recrée les vues gold_pilotage et gold_recherche."""
    log.info("Construction de la couche Gold (pilotage + recherche)...")
    config.exec_sql_file(ch, "gold_pilotage.sql")
    log.info("  gold_pilotage : OK")
    config.exec_sql_file(ch, "gold_recherche.sql")
    log.info("  gold_recherche : OK")
    log.info("Gold prête.")
