"""
ÉTAPE 3 — COUCHE GOLD

Rôle : créer les vues analytiques exposées à Metabase, cloisonnées par usage.

Gold = deux bases ClickHouse séparées :
  - gold_pilotage  : accessible au groupe Metabase "operationnels"
  - gold_recherche : accessible au groupe Metabase "chercheurs"

Implémentation : des VIEWS sur les tables Silver.
  - Avantage vs tables : aucune duplication de données, toujours fraîches.
  - Les vues sont légères à recréer (juste des définitions SQL).
  - Metabase lit les vues → ClickHouse exécute la requête Silver sous-jacente.

Cloisonnement des droits :
  Les deux bases sont séparées au niveau ClickHouse. Dans Metabase, on crée
  deux connexions distinctes (une par base) et deux groupes d'utilisateurs.
  Un chercheur ne voit que gold_recherche, un opérationnel que gold_pilotage.

RGPD renforcé côté recherche :
  - HAVING >= 5 : toute cohorte < 5 patients est supprimée des vues
  - region_code absent de gold_recherche (minimisation)
  - stay_id absent de fact_diagnostic (évite la jointure vers pilotage)
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
    """Crée les deux schémas Gold (pilotage et recherche) avec leurs vues et KPI.

    Gold est implémenté en VUES sur Silver (pas en tables).
    Avantage : aucune duplication de données, les vues sont toujours fraîches.
    Recréer les vues (CREATE OR REPLACE VIEW) est quasi-instantané.

    Deux bases séparées pour le cloisonnement des droits :
      - gold_pilotage  : opérationnels (direction, cadres de santé)
                         → region_code disponible, toutes les données de séjour
      - gold_recherche : chercheurs cliniques
                         → region_code absent, stay_id absent de fact_diagnostic,
                           toute cohorte < 5 patients supprimée (RGPD)

    Dans Metabase, deux connexions distinctes pointent vers ces deux bases,
    avec deux groupes d'utilisateurs : un opérationnel ne voit pas gold_recherche
    et un chercheur ne voit pas gold_pilotage.
    """
    log.info("Construction de la couche Gold (pilotage + recherche)...")
    _exec_sql_file(ch, _sql_path("gold_pilotage.sql"))
    log.info("  gold_pilotage : OK")
    _exec_sql_file(ch, _sql_path("gold_recherche.sql"))
    log.info("  gold_recherche : OK")
    log.info("Gold prête.")
