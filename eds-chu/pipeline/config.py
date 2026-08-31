"""
Chargement de la configuration depuis le fichier .env.
Toutes les valeurs sensibles (sel RGPD, mot de passe) passent par .env,
jamais en dur dans le code.
"""
import os
from pathlib import Path

from dotenv import load_dotenv

# Cherche .env dans le répertoire eds-chu/ (parent de pipeline/)
load_dotenv(Path(__file__).parent.parent / ".env")


def _require(key: str) -> str:
    val = os.environ.get(key)
    if not val:
        raise EnvironmentError(
            f"Variable d'environnement manquante : {key}\n"
            f"Copier .env.example en .env et renseigner la valeur."
        )
    return val


# Sel de pseudonymisation — NE JAMAIS logger ni afficher
PIPELINE_SALT: bytes = _require("PIPELINE_SALT").encode()

# Chemins
SOURCE_DIR = Path(_require("SOURCE_DIR"))
LAKE_DIR   = Path(_require("LAKE_DIR"))

# ClickHouse
CLICKHOUSE_HOST     = os.environ.get("CLICKHOUSE_HOST", "localhost")
CLICKHOUSE_PORT     = int(os.environ.get("CLICKHOUSE_PORT", "8123"))
CLICKHOUSE_USER     = os.environ.get("CLICKHOUSE_USER", "default")
CLICKHOUSE_PASSWORD = os.environ.get("CLICKHOUSE_PASSWORD", "")
