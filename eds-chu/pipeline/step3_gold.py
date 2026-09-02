"""
ÉTAPE 3 — COUCHE GOLD

Crée les vues des deux bases gold_pilotage et gold_recherche
(sql/gold_*.sql). Ce sont des VIEWS sur Silver, pas des tables.

Les droits ClickHouse sont appliqués ensuite (step4). Les vues sont
en SQL SECURITY DEFINER : un compte Gold peut les lire sans droit
sur silver.
"""
import logging
from pathlib import Path

log = logging.getLogger(__name__)


def _sql_path(name: str) -> Path:
    return Path(__file__).parent.parent / "sql" / name


def _exec_sql_file(ch, path: Path) -> None:
    """Exécute un fichier SQL statement par statement (séparateur : ';')."""
    sql = path.read_text()
    no_comments = "\n".join(
        l for l in sql.splitlines() if not l.strip().startswith("--")
    )
    for stmt in no_comments.split(";"):
        clean = stmt.strip()
        if clean:
            ch.command(clean)


def build_gold(ch) -> None:
    """Recrée les vues gold_pilotage et gold_recherche."""
    log.info("Construction de la couche Gold (pilotage + recherche)...")
    _exec_sql_file(ch, _sql_path("gold_pilotage.sql"))
    log.info("  gold_pilotage : OK")
    _exec_sql_file(ch, _sql_path("gold_recherche.sql"))
    log.info("  gold_recherche : OK")
    log.info("Gold prête.")
