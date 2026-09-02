"""
ÉTAPE 2 — COUCHE SILVER

Envoie sql/silver.sql à ClickHouse. Toute la logique de qualité est dans
ce SQL, pas ici. Silver est reconstruite entièrement à chaque run
(CREATE OR REPLACE) ; l'incrémentalité est gérée en Bronze.
"""
import logging
from pathlib import Path

log = logging.getLogger(__name__)


def _sql_path() -> Path:
    return Path(__file__).parent.parent / "sql" / "silver.sql"


def _exec_sql_file(ch, path: Path) -> None:
    """Exécute un fichier SQL statement par statement (séparateur : ';').

    Les commentaires sont supprimés avant le split pour éviter qu'un ';'
    dans un commentaire soit interprété comme un séparateur d'instruction.
    """
    sql = path.read_text()
    no_comments = "\n".join(
        l for l in sql.splitlines() if not l.strip().startswith("--")
    )
    for stmt in no_comments.split(";"):
        clean = stmt.strip()
        if clean:
            ch.command(clean)


def build_silver(ch) -> None:
    """Reconstruit Silver depuis Bronze via silver.sql."""
    log.info("Construction de la couche Silver...")
    _exec_sql_file(ch, _sql_path())
    log.info("Silver prête.")
