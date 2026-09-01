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
    """Reconstruit entièrement la couche Silver depuis Bronze.

    Silver est recréée à chaque run avec CREATE OR REPLACE TABLE (atomique).
    Ce choix est intentionnel : Silver n'accumule pas de données, elle transforme.
    Reconstruire est rapide (<1s sur ce volume) et garantit qu'il n'y a jamais
    de résidu d'un run précédent partiel ou raté.

    Toute la logique métier est dans silver.sql :
      - Déduplication des patients (argMax sur _source_date)
      - Filtrage des séjours incohérents (discharge < admission)
      - Calcul des réadmissions à 30 jours (fenêtre glissante SQL)
      - Agrégation des alertes monitoring par séjour
      - Enrichissement CIM-10 avec le chapitre (dérivé du 1er caractère)
    Python ne fait qu'envoyer les requêtes — pas de pandas, pas de traitement en mémoire.
    """
    log.info("Construction de la couche Silver...")
    _exec_sql_file(ch, _sql_path())
    log.info("Silver prête.")
