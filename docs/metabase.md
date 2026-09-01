# Configuration Metabase — EDS CHU

Metabase est accessible à **http://localhost:3001** (port 3001 car le 3000 est réservé au portfolio).

---

## Pré-requis

Avant d'ouvrir Metabase, s'assurer que :

1. Le container tourne : `docker compose ps` → `metabase` en état `Up`
2. Le driver ClickHouse est chargé : `docker compose logs metabase | grep clickhouse` doit afficher `Registered driver :clickhouse`
3. Le pipeline a été exécuté au moins une fois (`python -m pipeline.run`) → les bases `gold_pilotage` et `gold_recherche` existent dans ClickHouse

---

## Étape 1 — Créer le compte administrateur

À la première ouverture, Metabase lance un assistant de bienvenue.

1. Cliquer **Let's get started**
2. Renseigner n'importe quel nom, email et mot de passe (compte local, pas de vérification d'email)
3. Sur l'écran « Add your data » → cliquer **I'll add my data later** — on configure les connexions manuellement à l'étape suivante
4. Terminer l'assistant

---

## Étape 2 — Ajouter la connexion Pilotage

Chemin : icône engrenage (en haut à droite) → **Admin settings** → **Databases** → bouton **Add a database**

Remplir le formulaire :

| Champ | Valeur |
|---|---|
| **Database type** | `ClickHouse` ← doit apparaître dans la liste si le driver est chargé |
| **Display name** | `Pilotage hospitalier` |
| **Host** | `clickhouse` ← nom du service Docker, **pas** `localhost` |
| **Port** | `8123` |
| **Username** | `default` |
| **Password** | *(laisser vide)* |
| **Database name** | `gold_pilotage` |

Cliquer **Save** puis attendre quelques secondes → **Sync database schema now**.

> Si `ClickHouse` n'apparaît pas dans la liste des types de bases : vérifier que le driver est chargé (`docker compose logs metabase | grep clickhouse`). Si non, faire `docker compose restart metabase` après avoir vérifié que `metabase-plugins/clickhouse.metabase-driver.jar` existe et que le répertoire est accessible en écriture (`chmod 777 metabase-plugins/`).

---

## Étape 3 — Ajouter la connexion Recherche

Même chemin : **Databases** → **Add a database**

| Champ | Valeur |
|---|---|
| **Database type** | `ClickHouse` |
| **Display name** | `Recherche clinique` |
| **Host** | `clickhouse` |
| **Port** | `8123` |
| **Database name** | `gold_recherche` |
| **Username** | `default` |
| **Password** | *(laisser vide)* |

Cliquer **Save** → **Sync database schema now**.

---

## Étape 4 — Créer les groupes d'utilisateurs

Chemin : **Admin settings** → **People** → onglet **Groups** → **Create a group**

Créer deux groupes :
- `operationnels`
- `chercheurs`

---

## Étape 5 — Configurer les permissions d'accès aux données

Chemin : **Admin settings** → **Permissions** → onglet **Data**

La vue affiche un tableau : lignes = groupes, colonnes = bases de données.

Configurer comme suit :

| Groupe | Pilotage hospitalier | Recherche clinique |
|---|---|---|
| `operationnels` | **Can view** | **No self-service** |
| `chercheurs` | **No self-service** | **Can view** |
| `All Users` | **No self-service** | **No self-service** |

Pour modifier une cellule : cliquer dessus → sélectionner la valeur → cliquer **Save changes** en haut à droite.

> Le groupe `All Users` contient tout le monde par défaut. Le restreindre à `No self-service` sur les deux bases garantit qu'un compte non assigné n'a accès à rien.

---

## Étape 6 — Créer les utilisateurs

Chemin : **Admin settings** → **People** → **Invite someone**

Pour chaque utilisateur :
1. Renseigner l'email et définir un mot de passe temporaire
2. Dans la section **Groups**, cocher le groupe approprié (`operationnels` ou `chercheurs`)
3. Cliquer **Create**

L'utilisateur se connecte avec son email et mot de passe. Il voit uniquement la base à laquelle son groupe a accès.

---

## Étape 7 — Vérifier les connexions

Dans **Admin settings** → **Databases**, les deux bases doivent afficher un statut de synchronisation vert.

Test rapide depuis l'interface SQL de ClickHouse (http://localhost:8123/play) :

```sql
-- Pilotage
SELECT count() FROM gold_pilotage.fact_sejour;

-- Recherche
SELECT count() FROM gold_recherche.fact_diagnostic;
```

Depuis Metabase : **New** → **SQL query** → sélectionner `Pilotage hospitalier` → exécuter `SELECT count(*) FROM fact_sejour`.

---

## Dépannage

**`ClickHouse` absent de la liste des types de bases**

```bash
# Vérifier que le JAR est présent
ls -la eds-chu/metabase-plugins/clickhouse.metabase-driver.jar

# Vérifier les permissions du répertoire (doit être rwxrwxrwx)
ls -ld eds-chu/metabase-plugins/

# Si permissions incorrectes
chmod 777 eds-chu/metabase-plugins/

# Redémarrer Metabase et vérifier le chargement
docker compose restart metabase
docker compose logs metabase | grep clickhouse
# → doit afficher : Registered driver :clickhouse
```

**Connexion ClickHouse échoue dans Metabase**

- Hôte : utiliser `clickhouse` (nom du service Docker), jamais `localhost`
- Port : `8123` (HTTP), pas `9000` (protocole natif)
- Mot de passe : laisser vide (pas de mot de passe configuré en dev local)

**Metabase inaccessible**

```bash
docker compose logs metabase | tail -30
docker compose restart metabase
# Metabase prend ~2 minutes à démarrer
```
