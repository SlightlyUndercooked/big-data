# Configuration Metabase — EDS CHU

Metabase est accessible à **http://localhost:3001**

---

## Pré-requis

Avant d'ouvrir Metabase, s'assurer que :

1. Le container tourne : `docker compose ps` → `metabase` en état `Up`
2. Le driver ClickHouse est chargé : `docker compose logs metabase | grep clickhouse` doit afficher `Registered driver :clickhouse`
3. Le pipeline a été exécuté au moins une fois (`docker compose logs pipeline`) → les bases `gold_pilotage` et `gold_recherche` existent dans ClickHouse

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
| **Username** | `eds_pilotage` ← **pas** `default` |
| **Password** | valeur de `GOLD_PILOTAGE_PASSWORD` dans `eds-chu/.env` |
| **Database name** | `gold_pilotage` |

> **Pourquoi pas le compte `default` ?** `default` est le compte admin : il voit
> Bronze, Silver et les deux bases Gold. L'utiliser reviendrait à ne cloisonner
> que l'affichage Metabase — n'importe qui récupérant ces identifiants (ils sont
> lisibles dans l'écran d'admin Metabase) pourrait interroger ClickHouse
> directement sur le port 8123 et lire tout l'entrepôt. Le compte `eds_pilotage`
> est créé par le pipeline (`step4_grants.py`) avec `SELECT` sur `gold_pilotage`
> et rien d'autre.

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
| **Username** | `eds_recherche` ← **pas** `default` |
| **Password** | valeur de `GOLD_RECHERCHE_PASSWORD` dans `eds-chu/.env` |

Cliquer **Save** → **Sync database schema now**.

---

## Étape 4 — Créer les groupes d'utilisateurs

> Automatisable : `docker compose exec pipeline python -m pipeline.metabase_setup` (voir étape 8, option A)
> crée les groupes, les permissions et les utilisateurs de démonstration.
> Les étapes 4 à 6 ci-dessous documentent l'équivalent manuel.

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

## Étape 8 — Construire les deux dashboards

### Option A — Création automatique (recommandé)

Le script `pipeline/metabase_setup.py` automatise les **étapes 2 à 6 et 8**
via l'API REST de Metabase :

- suppression du contenu d'exemple Metabase (Sample Database, « E-commerce Insights »)
- les deux connexions ClickHouse (étapes 2-3), avec les comptes cloisonnés
- deux collections, une question par vue Gold avec la visualisation adaptée,
  et les deux dashboards avec leur mise en page (étape 8)
- les groupes `operationnels` et `chercheurs` (étape 4)
- les permissions données **et** collections (étape 5) : chaque groupe ne voit
  que sa connexion et sa collection
- deux utilisateurs de démonstration, un par groupe (étape 6) :
  `pilote@eds-chu.local` et `chercheur@eds-chu.local`

Pré-requis : renseigner dans `eds-chu/.env` les identifiants du compte admin
créé à l'étape 1 (et, optionnellement, les mots de passe des comptes démo) :

```bash
METABASE_URL=http://localhost:3001
METABASE_ADMIN_EMAIL=...
METABASE_ADMIN_PASSWORD=...
METABASE_PILOTE_PASSWORD=...
METABASE_CHERCHEUR_PASSWORD=...
```

Puis lancer :

```bash
docker compose exec pipeline python -m pipeline.metabase_setup
```

Le script est **idempotent** : il retrouve les connexions, groupes, questions
et dashboards par leur nom et les met à jour au lieu de les dupliquer. On peut
donc le relancer après chaque évolution des vues Gold.

> **Nuance version open source :** le niveau « Blocked » (la base disparaît
> totalement de Metabase) est réservé à la version Enterprise. Le script
> applique donc l'équivalent OSS du « No self-service » : requêtes interdites
> (`create-queries: no`), téléchargements bloqués et collection masquée.
> Ce n'est pas un trou de sécurité : le cloisonnement réel est garanti au
> niveau moteur par `step4_grants.py` (étape 9), et chaque connexion Metabase
> utilise un compte ClickHouse qui ne peut physiquement lire que sa base Gold.

### Option B — Création manuelle

Les vues Gold sont prêtes à l'emploi : chacune correspond à une carte. Pour chaque
vue, faire **New** → **Question** → choisir la base → choisir la vue → **Visualize**,
puis **Save** et l'ajouter au dashboard.

### Dashboard « Pilotage hospitalier » (base `Pilotage hospitalier`)

| Vue | Visualisation |
|---|---|
| `v_data_freshness` | Table |
| `v_sejours_en_cours` | Table, triée sur `jours_depuis_admission` |
| `v_dms_par_service` | Barres horizontales (`service_label` × `dms_jours`) |
| `v_dms_par_service_mois` | Courbe (`mois` en X, une série par `service_label`) |
| `v_activite_urgences` | Courbe (`jour` × `nb_passages`) |
| `v_taux_readmission_30j` | Nombre unique (taux global) |
| `v_mortalite` | Table (service × mode d'admission) |
| `v_alertes_monitoring_par_jour` | 3 courbes (désaturation, brady/tachycardie, fièvre) |
| `v_alertes_par_service` | Barres empilées par type d'alerte |

### Dashboard « Recherche clinique » (base `Recherche clinique`)

| Vue | Visualisation suggérée |
|---|---|
| `v_prevalence_pathologies` | Barres (`libelle` × `nb_patients`) |
| `v_prevalence_mensuelle` | Courbe (`mois` en X, une série par `libelle`) |
| `v_description_cohorte` | Barres empilées (`tranche_age_debut` × `nb_patients`, série = `sex`) |
| `v_comorbidites` | Table triée sur `nb_patients`, filtrable sur `code_principal` |

---

## Étape 9 — Démontrer le cloisonnement

Le cloisonnement est appliqué à **deux niveaux indépendants**. C'est ce qui permet
de le démontrer autrement que par une capture d'écran de l'interface.

**Niveau 1 — moteur (ClickHouse).** Les comptes `eds_pilotage` et `eds_recherche`
n'ont `SELECT` que sur leur base Gold. Ni Bronze, ni Silver, ni `meta`, ni la base
Gold de l'autre usage. Créés et réappliqués à chaque run par `step4_grants.py`.

**Niveau 2 — application (Metabase).** Les groupes `operationnels` et `chercheurs`
ne voient que leur connexion respective (étape 5).

Le niveau 1 est celui qui compte : même en contournant Metabase et en tapant
directement sur le port 8123, l'accès reste refusé. Preuve reproductible :

```bash
# Depuis eds-chu/, avec les mots de passe du .env
PIL="http://eds_pilotage:$GOLD_PILOTAGE_PASSWORD@localhost:8123/"
REC="http://eds_recherche:$GOLD_RECHERCHE_PASSWORD@localhost:8123/"

# Chaque compte ne voit QUE sa base
curl -s -G "$PIL" --data-urlencode "query=SHOW DATABASES"   # → gold_pilotage
curl -s -G "$REC" --data-urlencode "query=SHOW DATABASES"   # → gold_recherche

# Croisement interdit → ACCESS_DENIED
curl -s -G "$REC" --data-urlencode "query=SELECT count() FROM gold_pilotage.fact_sejour"
curl -s -G "$PIL" --data-urlencode "query=SELECT count() FROM gold_recherche.fact_diagnostic"

# Couches basses inaccessibles → ACCESS_DENIED
curl -s -G "$REC" --data-urlencode "query=SELECT count() FROM silver.fact_sejour"
curl -s -G "$PIL" --data-urlencode "query=SELECT count() FROM bronze.sejours"
```

Le cloisonnement moteur et les choix de visualisation sont détaillés dans
le [rapport partie 1](../rapport.md).

> **Point d'architecture — `SQL SECURITY DEFINER`**
> Les vues Gold lisent `silver.*`, alors que les comptes Gold n'ont aucun droit
> sur `silver`. Cela fonctionne parce que chaque vue est déclarée
> `DEFINER = CURRENT_USER SQL SECURITY DEFINER` : elle s'exécute avec les droits
> de son créateur (le compte admin du pipeline), pas ceux de l'appelant.
> La vue devient ainsi la frontière de sécurité — on accède aux données
> uniquement à travers la projection définie, et les colonnes qu'elle exclut
> (`stay_id`, `service_code`, `region_code` côté recherche) sont réellement
> inatteignables, pas seulement masquées.
> Sans cette clause, toutes les requêtes Metabase échoueraient en
> « Not enough privileges ».

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
