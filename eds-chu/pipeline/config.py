"""
Chargement configuration depuis .env.
"""
import os
from pathlib import Path

from dotenv import load_dotenv

load_dotenv(Path(__file__).parent.parent / ".env")


def _require(key: str) -> str:
    val = os.environ.get(key)
    if not val:
        raise EnvironmentError(
            f"Variable d'environnement manquante : {key}\n"
            f"Copier .env.example en .env et renseigner la valeur."
        )
    return val


PIPELINE_SALT: bytes = _require("PIPELINE_SALT").encode()

_ENV_DIR = Path(__file__).parent.parent

def _resolve(key: str) -> Path:
    p = Path(_require(key))
    return p if p.is_absolute() else _ENV_DIR / p

SOURCE_DIR = _resolve("SOURCE_DIR")
LAKE_DIR   = _resolve("LAKE_DIR")
SQL_DIR    = _ENV_DIR / "sql"

CLICKHOUSE_HOST     = os.environ.get("CLICKHOUSE_HOST", "localhost")
try:
    CLICKHOUSE_PORT = int(os.environ.get("CLICKHOUSE_PORT", "8123"))
except ValueError as exc:
    raise EnvironmentError(
        f"CLICKHOUSE_PORT doit être un entier, pas "
        f"{os.environ.get('CLICKHOUSE_PORT')!r}"
    ) from exc
CLICKHOUSE_USER     = os.environ.get("CLICKHOUSE_USER", "default")
CLICKHOUSE_PASSWORD = os.environ.get("CLICKHOUSE_PASSWORD", "")

# Comptes lecture seule Metabase (un par base Gold) — pas le compte admin.
GOLD_PILOTAGE_PASSWORD  = _require("GOLD_PILOTAGE_PASSWORD")
GOLD_RECHERCHE_PASSWORD = _require("GOLD_RECHERCHE_PASSWORD")


def exec_sql_file(ch, filename: str) -> None:
    """Exécute un fichier de sql/ statement par statement.

    Les commentaires `--` sont retirés avant le split sur ';' : un
    point-virgule dans un commentaire ne doit pas couper l'instruction.
    En cas d'échec, le nom du fichier et un extrait de l'instruction
    fautive sont joints à l'exception (sinon ClickHouse ne dit pas
    *quelle* vue / table a cassé le run).
    """
    path = SQL_DIR / filename
    if not path.is_file():
        raise FileNotFoundError(f"Fichier SQL introuvable : {path}")

    sql = path.read_text()
    no_comments = "\n".join(
        l for l in sql.splitlines() if not l.strip().startswith("--")
    )
    statements = [s.strip() for s in no_comments.split(";") if s.strip()]
    for i, clean in enumerate(statements, start=1):
        try:
            ch.command(clean)
        except Exception as exc:
            preview = " ".join(clean.split())[:200]
            raise RuntimeError(
                f"Échec SQL dans {filename} (instruction {i}/{len(statements)}) : {exc}\n"
                f"  {preview}"
            ) from exc
