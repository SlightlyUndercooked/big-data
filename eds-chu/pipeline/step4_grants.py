"""
ÉTAPE 4 — DROITS CLICKHOUSE

Comptes lecture seule pour Metabase :
  eds_pilotage  → SELECT gold_pilotage.*
  eds_recherche → SELECT gold_recherche.*
Rien d'autre (ni bronze, ni silver, ni l'autre Gold).

Les permissions Metabase ne suffisent pas : les identifiants de
connexion sont visibles côté admin. Le moteur doit refuser l'accès.

Les vues Gold sont SQL SECURITY DEFINER (sql/gold_*.sql) : un compte
sans droit sur silver peut quand même lire la projection.

ClickHouse n'a pas CREATE OR REPLACE USER. Séquence rejouable :
  CREATE USER IF NOT EXISTS → ALTER (mdp du .env) → REVOKE ALL → GRANT SELECT
REVOKE avant GRANT efface un droit ajouté à la main. ALTER plutôt que
DROP pour ne pas couper une session Metabase ouverte.
"""
import logging

from . import config

log = logging.getLogger(__name__)


def _gold_accounts() -> list[tuple[str, str, str]]:
    return [
        ("eds_pilotage",  "gold_pilotage",  config.GOLD_PILOTAGE_PASSWORD),
        ("eds_recherche", "gold_recherche", config.GOLD_RECHERCHE_PASSWORD),
    ]


def _sql_string(value: str) -> str:
    """Encode une valeur en littéral chaîne SQL ClickHouse.

    Les noms de comptes et de bases sont des constantes du code, mais le mot
    de passe vient du .env : il est interpolé dans du DDL, que ClickHouse ne
    sait pas paramétrer. On échappe donc explicitement antislash et quote
    simple plutôt que de concaténer la valeur telle quelle.
    """
    escaped = value.replace("\\", "\\\\").replace("'", "\\'")
    return f"'{escaped}'"


def build_grants(ch) -> None:
    """Crée/réinitialise les comptes Gold et applique leurs droits."""
    log.info("Application du cloisonnement des accès (comptes Gold)...")

    for user, database, password in _gold_accounts():
        ch.command(f"CREATE USER IF NOT EXISTS {user} NOT IDENTIFIED")
        ch.command(
            f"ALTER USER {user} "
            f"IDENTIFIED WITH sha256_password BY {_sql_string(password)}"
        )
        ch.command(f"REVOKE ALL ON *.* FROM {user}")
        ch.command(f"GRANT SELECT ON {database}.* TO {user}")
        log.info(f"  {user} : SELECT sur {database} uniquement")

    log.info("Cloisonnement appliqué.")
