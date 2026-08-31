"""
ÉTAPE 2 — COUCHE SILVER

Rôle : nettoyer, dédupliquer et enrichir les données Bronze.
TOUTE la logique métier est dans le fichier SQL (sql/silver.sql).
Ici on ne fait qu'envoyer les requêtes à ClickHouse.

Silver est reconstruite entièrement à chaque run (CREATE OR REPLACE TABLE).
Cela garantit que Silver reflète toujours l'état complet de Bronze,
sans risque de données orphelines ou de conflits d'incrémental.
L'incrémentalité est gérée au niveau Bronze (on n'insère pas deux fois
la même date source).

Contrôles qualité appliqués en SQL Silver (cf. sql/silver.sql) :
  - patients : déduplication par argMax(_source_date), filtre sex IN ('M','F')
  - séjours : écart si discharge_ts < admission_ts (136 cas détectés)
  - monitoring : comptage des alertes hors plage physiologique par séjour
  - diagnostics : inner join avec séjours valides (écarte les diagnostics orphelins)
  - réadmissions: calcul par fenêtre glissante (lagInFrame) en SQL ClickHouse
"""
import logging
from pathlib import Path

log = logging.getLogger(__name__)


def _sql_path() -> Path:
    return Path(__file__).parent.parent / "sql" / "silver.sql"


def _exec_sql_file(ch, path: Path) -> None:
    """Exécute un fichier SQL statement par statement (séparateur : ';')."""
    sql = path.read_text()
    for stmt in sql.split(";"):
        stmt = stmt.strip()
        lines = [l for l in stmt.splitlines() if not l.strip().startswith("--")]
        clean = "\n".join(lines).strip()
        if clean:
            ch.command(clean)


def build_silver(ch) -> None:
    log.info("Construction de la couche Silver...")
    _exec_sql_file(ch, _sql_path())
    log.info("Silver prête.")
