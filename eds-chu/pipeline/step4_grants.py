"""
ÉTAPE 4 — CLOISONNEMENT DES ACCÈS (droits ClickHouse)

Rôle : créer les deux comptes ClickHouse en lecture seule utilisés par
Metabase, et n'accorder à chacun que sa base Gold.

POURQUOI CETTE ÉTAPE
  Le cloisonnement pilotage / recherche exigé par le sujet (§5) ne peut pas
  reposer uniquement sur les permissions Metabase. Tant que les deux
  connexions Metabase utilisent le compte admin `default`, le cloisonnement
  n'est qu'un réglage d'interface : quiconque obtient les identifiants de
  connexion (ils sont visibles en clair dans l'écran d'admin Metabase, et
  dans le .env) peut interroger ClickHouse directement sur le port 8123 et
  lire l'intégralité de l'entrepôt, Bronze et Silver compris.
  Le cloisonnement doit donc être appliqué par le moteur lui-même.

MODÈLE DE DROITS
  eds_pilotage  → SELECT sur gold_pilotage.*  uniquement
  eds_recherche → SELECT sur gold_recherche.* uniquement
  Aucun des deux n'a le moindre droit sur bronze, silver, meta, ni sur la
  base Gold de l'autre usage.

  Les vues Gold sont déclarées SQL SECURITY DEFINER (cf. sql/gold_*.sql) :
  elles s'exécutent avec les droits de leur créateur. C'est ce qui permet à
  un compte n'ayant AUCUN droit sur silver de lire malgré tout une vue Gold
  bâtie sur silver. La vue devient la frontière : on accède aux données
  uniquement à travers la projection définie, jamais aux tables sources.

IDEMPOTENCE
  ClickHouse ne connaît pas CREATE OR REPLACE USER (réservé aux TABLE,
  VIEW, DICTIONARY et FUNCTION). La séquence rejouable est donc :
    CREATE USER IF NOT EXISTS  → crée le compte au premier run
    ALTER USER ... IDENTIFIED  → réaligne le mot de passe sur le .env
    REVOKE ALL ON *.*          → repart d'un compte sans aucun droit
    GRANT SELECT ON <gold>.*   → n'accorde que le strict nécessaire
  Le REVOKE avant GRANT est ce qui rend l'étape réellement idempotente :
  un droit accordé manuellement hors pipeline est effacé au run suivant,
  donc le .env et ce fichier restent la seule source de vérité.
  On préfère ALTER à un DROP/CREATE pour ne pas couper les connexions
  Metabase ouvertes pendant que le pipeline tourne.
"""
import logging

from . import config

log = logging.getLogger(__name__)


# (nom du compte ClickHouse, base Gold accessible, mot de passe)
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
        # Table rase avant d'accorder : efface tout droit accordé hors
        # pipeline, pour que ce fichier reste la seule source de vérité.
        ch.command(f"REVOKE ALL ON *.* FROM {user}")
        ch.command(f"GRANT SELECT ON {database}.* TO {user}")
        log.info(f"  {user} : SELECT sur {database} uniquement")

    log.info("Cloisonnement appliqué.")
