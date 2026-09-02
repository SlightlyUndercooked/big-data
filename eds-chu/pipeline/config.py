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


# Sel de pseudonymisation 
PIPELINE_SALT: bytes = _require("PIPELINE_SALT").encode()

SOURCE_DIR = Path(_require("SOURCE_DIR"))
LAKE_DIR   = Path(_require("LAKE_DIR"))

# ClickHouse — compte admin utilisé par le pipeline pour construire les couches
CLICKHOUSE_HOST     = os.environ.get("CLICKHOUSE_HOST", "localhost")
CLICKHOUSE_PORT     = int(os.environ.get("CLICKHOUSE_PORT", "8123"))
CLICKHOUSE_USER     = os.environ.get("CLICKHOUSE_USER", "default")
CLICKHOUSE_PASSWORD = os.environ.get("CLICKHOUSE_PASSWORD", "")

# Cloisonnement Gold : comptes ClickHouse en lecture seule, un par usage.
# Ce sont ces comptes que Metabase utilise pour ses deux connexions —
# jamais le compte admin ci-dessus. Chacun ne voit que sa base Gold.
GOLD_PILOTAGE_PASSWORD  = _require("GOLD_PILOTAGE_PASSWORD")
GOLD_RECHERCHE_PASSWORD = _require("GOLD_RECHERCHE_PASSWORD")
