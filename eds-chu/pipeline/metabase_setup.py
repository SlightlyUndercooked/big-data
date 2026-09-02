"""
AUTOMATISATION METABASE — connexions, questions et dashboards

Usage :
    cd eds-chu/
    python -m pipeline.metabase_setup

Pré-requis :
    - Metabase initialisé (compte admin créé via l'assistant au premier lancement)
    - METABASE_ADMIN_EMAIL / METABASE_ADMIN_PASSWORD renseignés dans .env
    - Pipeline exécuté au moins une fois (les vues Gold et les comptes
      eds_pilotage / eds_recherche doivent exister — cf. step4_grants)

Ce que fait le script (idempotent, rejouable sans dupliquer) :
    1. Connexions ClickHouse "Pilotage hospitalier" et "Recherche clinique",
       avec les comptes cloisonnés eds_pilotage / eds_recherche (jamais default)
    2. Deux collections pour ranger les questions
    3. Une question (carte) par vue Gold, avec la visualisation adaptée
    4. Deux dashboards ("Pilotage hospitalier", "Recherche clinique") avec
       les cartes disposées sur la grille
    5. Groupes "operationnels" et "chercheurs"
    6. Permissions données ET collections : chaque groupe ne voit que sa
       connexion et sa collection (All Users ne voit rien)
    7. Deux utilisateurs de démonstration (un par groupe)

L'idempotence repose sur la recherche par nom : si une connexion, collection,
question ou dashboard du même nom existe déjà (non archivé), il est réutilisé
et mis à jour au lieu d'être recréé.
"""
import logging
import os
import sys

import requests

from . import config

log = logging.getLogger(__name__)

MB_URL = os.environ.get("METABASE_URL", "http://localhost:3001").rstrip("/")
MB_EMAIL = os.environ.get("METABASE_ADMIN_EMAIL", "")
MB_PASSWORD = os.environ.get("METABASE_ADMIN_PASSWORD", "")

GRID_WIDTH = 24
HALF = GRID_WIDTH // 2


# Client API minimal

class Metabase:
    """Petit client REST Metabase authentifié par session."""

    def __init__(self, url: str, email: str, password: str):
        self.url = url
        r = requests.post(
            f"{url}/api/session",
            json={"username": email, "password": password},
            timeout=30,
        )
        if r.status_code != 200:
            raise SystemExit(
                f"Connexion Metabase refusée ({r.status_code}) : {r.text}\n"
                "Vérifier METABASE_ADMIN_EMAIL / METABASE_ADMIN_PASSWORD dans .env"
            )
        self.headers = {"X-Metabase-Session": r.json()["id"]}

    def get(self, path: str):
        r = requests.get(f"{self.url}/api{path}", headers=self.headers, timeout=30)
        r.raise_for_status()
        return r.json()

    def post(self, path: str, payload: dict):
        r = requests.post(
            f"{self.url}/api{path}", json=payload, headers=self.headers, timeout=60
        )
        if r.status_code not in (200, 202):
            raise RuntimeError(f"POST {path} → {r.status_code} : {r.text}")
        return r.json() if r.text else {}

    def put(self, path: str, payload: dict):
        r = requests.put(
            f"{self.url}/api{path}", json=payload, headers=self.headers, timeout=60
        )
        if r.status_code != 200:
            raise RuntimeError(f"PUT {path} → {r.status_code} : {r.text}")
        return r.json() if r.text else {}

    def delete(self, path: str) -> None:
        r = requests.delete(f"{self.url}/api{path}", headers=self.headers, timeout=60)
        if r.status_code not in (200, 204):
            raise RuntimeError(f"DELETE {path} → {r.status_code} : {r.text}")


def remove_sample_content(mb: Metabase) -> None:
    """Supprime la base d'exemple Metabase et archive ses contenus de démo.

    Sans cela, le dashboard « E-commerce Insights » et la Sample Database
    restent visibles par tous les groupes — hors sujet pour l'EDS.
    """
    for db in mb.get("/database")["data"]:
        if db.get("is_sample"):
            mb.delete(f"/database/{db['id']}")
            log.info(f"Base d'exemple '{db['name']}' : supprimée")
    for coll in mb.get("/collection"):
        if coll.get("is_sample") and not coll.get("archived"):
            mb.put(f"/collection/{coll['id']}", {"archived": True})
            log.info(f"Collection d'exemple '{coll['name']}' : archivée")


# Connexions clicklhouse

def ensure_database(mb: Metabase, name: str, dbname: str, user: str, password: str) -> int:
    """Crée (ou retrouve) une connexion ClickHouse et retourne son id."""
    for db in mb.get("/database")["data"]:
        if db["name"] == name:
            log.info(f"Connexion '{name}' : déjà présente (id={db['id']})")
            return db["id"]

    created = mb.post("/database", {
        "engine": "clickhouse",
        "name": name,
        "details": {
            # Nom du service Docker : Metabase tourne dans le même réseau
            # compose que ClickHouse, 'localhost' ne fonctionnerait pas.
            "host": "clickhouse",
            "port": 8123,
            "user": user,
            "password": password,
            "dbname": dbname,
            "ssl": False,
        },
    })
    db_id = created["id"]
    mb.post(f"/database/{db_id}/sync_schema", {})
    log.info(f"Connexion '{name}' : créée (id={db_id})")
    return db_id


# Collections, questions, dashboards

def ensure_collection(mb: Metabase, name: str) -> int:
    for coll in mb.get("/collection"):
        if coll.get("name") == name and not coll.get("archived"):
            return coll["id"]
    created = mb.post("/collection", {"name": name})
    log.info(f"Collection '{name}' : créée (id={created['id']})")
    return created["id"]


def ensure_card(mb: Metabase, existing: dict, db_id: int, collection_id: int,
                name: str, sql: str, display: str, viz: dict) -> int:
    """Crée ou met à jour une question SQL native. Retourne son id."""
    payload = {
        "name": name,
        "collection_id": collection_id,
        "display": display,
        "visualization_settings": viz,
        "dataset_query": {
            "type": "native",
            "database": db_id,
            "native": {"query": sql},
        },
    }
    if name in existing:
        card_id = existing[name]
        mb.put(f"/card/{card_id}", payload)
        log.info(f"  Question '{name}' : mise à jour (id={card_id})")
        return card_id
    created = mb.post("/card", payload)
    log.info(f"  Question '{name}' : créée (id={created['id']})")
    return created["id"]


def ensure_dashboard(mb: Metabase, name: str, collection_id: int,
                     dashcards: list[dict]) -> int:
    """Crée (ou retrouve) un dashboard puis remplace sa mise en page."""
    dash_id = None
    for dash in mb.get("/dashboard"):
        if dash["name"] == name and not dash.get("archived"):
            dash_id = dash["id"]
            break
    if dash_id is None:
        dash_id = mb.post("/dashboard", {"name": name, "collection_id": collection_id})["id"]
        log.info(f"Dashboard '{name}' : créé (id={dash_id})")
    else:
        log.info(f"Dashboard '{name}' : existant (id={dash_id}), mise en page remplacée")

    # Les ids négatifs indiquent à Metabase de créer de nouvelles dashcards ;
    # l'ancienne disposition est intégralement remplacée (idempotence).
    for i, dc in enumerate(dashcards):
        dc.setdefault("id", -(i + 1))
        dc.setdefault("parameter_mappings", [])
        dc.setdefault("visualization_settings", {})
    mb.put(f"/dashboard/{dash_id}", {"dashcards": dashcards})
    return dash_id


# Définition des cartes
# Une carte par vue Gold

CARTES_PILOTAGE = [
    ("Fraîcheur des données",
     "SELECT * FROM v_data_freshness",
     "table", {}, GRID_WIDTH, 3),
    ("DMS par service",
     "SELECT service_label, dms_jours, nb_sejours_termines FROM v_dms_par_service ORDER BY dms_jours DESC",
     "row", {"graph.dimensions": ["service_label"], "graph.metrics": ["dms_jours"]}, HALF, 8),
    ("Activité des urgences (passages/jour)",
     "SELECT * FROM v_activite_urgences ORDER BY jour",
     "line", {"graph.dimensions": ["jour"], "graph.metrics": ["nb_passages"]}, HALF, 8),
    ("DMS par service et par mois",
     "SELECT * FROM v_dms_par_service_mois ORDER BY mois",
     "line", {"graph.dimensions": ["mois", "service_label"], "graph.metrics": ["dms_jours"]}, HALF, 8),
    # La vue est déjà globale (une seule ligne) : la carte affiche le taux tel quel.
    ("Taux de réadmission à 30 jours",
     "SELECT taux_readmission_pct FROM v_taux_readmission_30j",
     "scalar", {"scalar.suffix": " %"}, HALF, 8),
    ("Alertes monitoring par jour",
     "SELECT jour, nb_desaturations, nb_brady_tachycardies, nb_fievres FROM v_alertes_monitoring_par_jour ORDER BY jour",
     "line", {"graph.dimensions": ["jour"],
              "graph.metrics": ["nb_desaturations", "nb_brady_tachycardies", "nb_fievres"]}, HALF, 8),
    ("Alertes monitoring par service",
     "SELECT service_label, nb_desaturations, nb_brady_tachycardies, nb_fievres FROM v_alertes_par_service ORDER BY nb_desaturations + nb_brady_tachycardies + nb_fievres DESC",
     "bar", {"graph.dimensions": ["service_label"],
             "graph.metrics": ["nb_desaturations", "nb_brady_tachycardies", "nb_fievres"],
             "stackable.stack_type": "stacked"}, HALF, 8),
    ("Mortalité par service et mode d'admission",
     "SELECT * FROM v_mortalite ORDER BY taux_mortalite_pct DESC",
     "table", {}, HALF, 8),
    ("Séjours en cours",
     "SELECT * FROM v_sejours_en_cours ORDER BY jours_depuis_admission DESC",
     "table", {}, HALF, 8),
]

CARTES_RECHERCHE = [
    ("Prévalence des pathologies (patients distincts)",
     "SELECT libelle, nb_patients, nb_occurrences FROM v_prevalence_pathologies ORDER BY nb_patients DESC",
     "row", {"graph.dimensions": ["libelle"], "graph.metrics": ["nb_patients"]}, HALF, 8),
    ("Prévalence mensuelle par pathologie",
     "SELECT mois, libelle, nb_patients FROM v_prevalence_mensuelle ORDER BY mois",
     "line", {"graph.dimensions": ["mois", "libelle"], "graph.metrics": ["nb_patients"]}, HALF, 8),
    ("Description de la cohorte (âge × sexe)",
     "SELECT tranche_age_debut, sex, sum(nb_patients) AS nb_patients FROM v_description_cohorte GROUP BY tranche_age_debut, sex ORDER BY tranche_age_debut",
     "bar", {"graph.dimensions": ["tranche_age_debut", "sex"], "graph.metrics": ["nb_patients"],
             "stackable.stack_type": "stacked"}, HALF, 8),
    ("Comorbidités les plus fréquentes",
     "SELECT * FROM v_comorbidites ORDER BY nb_patients DESC LIMIT 50",
     "table", {}, HALF, 8),
]


# Groupes, permissions et utilisateurs (cf. docs/metabase.md, étapes 4-6)

def ensure_group(mb: Metabase, name: str) -> int:
    for grp in mb.get("/permissions/group"):
        if grp["name"] == name:
            return grp["id"]
    created = mb.post("/permissions/group", {"name": name})
    log.info(f"Groupe '{name}' : créé (id={created['id']})")
    return created["id"]


def set_data_permissions(mb: Metabase, rules: dict[int, dict[int, bool]]) -> None:
    """Applique le cloisonnement données : rules[group_id][db_id] = autorisé ?

    Autorisé → requêtes via l'éditeur graphique ("Can view" de la doc).
    Interdit → create-queries 'no', l'équivalent open source du
               "No self-service" : le groupe ne peut pas interroger la base.

    Le niveau "blocked" (la base disparaît totalement) est réservé à la
    version Enterprise — l'API renvoie 402 en OSS. Ce n'est pas un trou de
    sécurité ici : le compte ClickHouse de chaque connexion (eds_pilotage /
    eds_recherche) ne peut physiquement lire que sa base Gold (step4_grants),
    et les collections cachent les dashboards de l'autre profil.
    """
    graph = mb.get("/permissions/graph")
    for group_id, dbs in rules.items():
        group_perms = graph["groups"].setdefault(str(group_id), {})
        for db_id, allowed in dbs.items():
            group_perms[str(db_id)] = {
                "view-data": "unrestricted",
                "create-queries": "query-builder" if allowed else "no",
                "download": {"schemas": "full" if allowed else "none"},
            }
    mb.put("/permissions/graph", graph)
    log.info("Permissions données : appliquées")


def set_collection_permissions(mb: Metabase, rules: dict[int, dict[int, str]]) -> None:
    """Applique les droits de collections : rules[group_id][coll_id] = 'read'|'none'.

    Sans cela, tout utilisateur verrait les deux dashboards (même si les
    données sous-jacentes lui sont bloquées).
    """
    graph = mb.get("/collection/graph")
    for group_id, colls in rules.items():
        group_perms = graph["groups"].setdefault(str(group_id), {})
        for coll_id, level in colls.items():
            group_perms[str(coll_id)] = level
    mb.put("/collection/graph", graph)
    log.info("Permissions collections : appliquées")


def ensure_user(mb: Metabase, email: str, first_name: str, password: str,
                group_ids: list[int]) -> None:
    """Crée un utilisateur de démonstration rattaché à ses groupes."""
    existing = mb.get("/user?status=all").get("data", [])
    if any(u["email"] == email for u in existing):
        log.info(f"Utilisateur '{email}' : déjà présent")
        return
    all_users_id = next(
        g["id"] for g in mb.get("/permissions/group") if g["name"] == "All Users"
    )
    mb.post("/user", {
        "email": email,
        "first_name": first_name,
        "last_name": "EDS",
        "password": password,
        "user_group_memberships": [
            {"id": gid} for gid in [all_users_id, *group_ids]
        ],
    })
    log.info(f"Utilisateur '{email}' : créé (groupes {group_ids})")


def _layout(cards_meta: list[tuple], card_ids: list[int]) -> list[dict]:
    """Dispose les cartes sur la grille : remplit chaque ligne de gauche à droite."""
    dashcards, row, col, row_height = [], 0, 0, 0
    for (name, _sql, _display, _viz, size_x, size_y), card_id in zip(cards_meta, card_ids):
        if col + size_x > GRID_WIDTH:
            row += row_height
            col, row_height = 0, 0
        dashcards.append({
            "card_id": card_id,
            "row": row, "col": col,
            "size_x": size_x, "size_y": size_y,
        })
        col += size_x
        row_height = max(row_height, size_y)
    return dashcards


def build_dashboard(mb: Metabase, db_id: int, coll_name: str,
                    dash_name: str, cards_meta: list[tuple]) -> int:
    """Construit collection + questions + dashboard. Retourne l'id de la collection."""
    coll_id = ensure_collection(mb, coll_name)
    existing = {
        c["name"]: c["id"]
        for c in mb.get("/card")
        if not c.get("archived") and c.get("collection_id") == coll_id
    }
    card_ids = [
        ensure_card(mb, existing, db_id, coll_id, name, sql, display, viz)
        for name, sql, display, viz, _sx, _sy in cards_meta
    ]
    ensure_dashboard(mb, dash_name, coll_id, _layout(cards_meta, card_ids))
    return coll_id


def run() -> None:
    if not MB_EMAIL or not MB_PASSWORD:
        raise SystemExit(
            "METABASE_ADMIN_EMAIL et METABASE_ADMIN_PASSWORD doivent être "
            "renseignés dans eds-chu/.env (compte admin créé au premier "
            "lancement de Metabase)."
        )

    log.info("=" * 60)
    log.info(f"Metabase — configuration automatique ({MB_URL})")
    log.info("=" * 60)

    mb = Metabase(MB_URL, MB_EMAIL, MB_PASSWORD)

    remove_sample_content(mb)

    # Connexions avec les comptes clickHouse cloisonnés 
    db_pilotage = ensure_database(
        mb, "Pilotage hospitalier", "gold_pilotage",
        "eds_pilotage", os.environ.get("GOLD_PILOTAGE_PASSWORD", ""),
    )
    db_recherche = ensure_database(
        mb, "Recherche clinique", "gold_recherche",
        "eds_recherche", os.environ.get("GOLD_RECHERCHE_PASSWORD", ""),
    )

    coll_pilotage = build_dashboard(mb, db_pilotage, "Pilotage hospitalier",
                                    "Pilotage hospitalier", CARTES_PILOTAGE)
    coll_recherche = build_dashboard(mb, db_recherche, "Recherche clinique",
                                     "Recherche clinique", CARTES_RECHERCHE)

    # --- Cloisonnement applicatif (étapes 4-6 de docs/metabase.md) ---
    grp_ops = ensure_group(mb, "operationnels")
    grp_cher = ensure_group(mb, "chercheurs")
    all_users = next(
        g["id"] for g in mb.get("/permissions/group") if g["name"] == "All Users"
    )

    set_data_permissions(mb, {
        grp_ops:   {db_pilotage: True,  db_recherche: False},
        grp_cher:  {db_pilotage: False, db_recherche: True},
        all_users: {db_pilotage: False, db_recherche: False},
    })
    set_collection_permissions(mb, {
        grp_ops:   {coll_pilotage: "read", coll_recherche: "none"},
        grp_cher:  {coll_pilotage: "none", coll_recherche: "read"},
        all_users: {coll_pilotage: "none", coll_recherche: "none"},
    })

    # Utilisateurs de démonstration (un par profil) si mots de passe fournis.
    pilote_pwd = os.environ.get("METABASE_PILOTE_PASSWORD", "")
    chercheur_pwd = os.environ.get("METABASE_CHERCHEUR_PASSWORD", "")
    if pilote_pwd:
        ensure_user(mb, "pilote@eds-chu.local", "Pilote", pilote_pwd, [grp_ops])
    if chercheur_pwd:
        ensure_user(mb, "chercheur@eds-chu.local", "Chercheur", chercheur_pwd, [grp_cher])
    if not pilote_pwd or not chercheur_pwd:
        log.info("Utilisateurs démo : METABASE_PILOTE_PASSWORD / "
                 "METABASE_CHERCHEUR_PASSWORD absents du .env → non créés")

    log.info("=" * 60)
    log.info("Metabase — dashboards prêts :")
    log.info(f"  {MB_URL}/dashboard (Pilotage hospitalier, Recherche clinique)")
    log.info("=" * 60)


if __name__ == "__main__":
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(levelname)s] %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
    )
    try:
        run()
    except Exception as e:
        log.error(f"Erreur configuration Metabase : {e}")
        sys.exit(1)
