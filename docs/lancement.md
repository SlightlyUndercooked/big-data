# Guide de lancement — EDS CHU

## Pré-requis

- Docker + Docker Compose
- Python 3.11+
- Les fichiers source dans `source-filestorage/` (lecture seule, fournis par le CHU)

---

## Premier lancement (une seule fois)

### 1. Installer les dépendances Python

```bash
cd eds-chu/
pip install -r requirements.txt
```

### 2. Configurer l'environnement

```bash
cp .env.example .env
```

Éditer `.env` :

```env
PIPELINE_SALT=une_chaine_aleatoire_longue_et_secrete   # ne jamais changer après le premier run
SOURCE_DIR=/chemin/absolu/vers/source-filestorage
LAKE_DIR=/chemin/absolu/vers/eds-chu/lake
CLICKHOUSE_HOST=localhost
CLICKHOUSE_PORT=8123
CLICKHOUSE_USER=default
CLICKHOUSE_PASSWORD=
```

> **Important :** le `PIPELINE_SALT` génère tous les pseudonymes patients. Le changer invalide toutes les jointures existantes.

### 3. Télécharger le driver ClickHouse pour Metabase

```bash
curl -L https://github.com/ClickHouse/metabase-clickhouse-driver/releases/download/1.53.4/clickhouse.metabase-driver.jar \
     -o metabase-plugins/clickhouse.metabase-driver.jar
```

### 4. Démarrer les containers

```bash
docker compose up -d
```

- ClickHouse : http://localhost:8123/play (interface SQL)
- Metabase : http://localhost:3001 (dashboards) — démarre en ~2 min

### 5. Lancer le pipeline

```bash
python -m pipeline.run
```

Ce que fait le pipeline :
1. Copie les fichiers source vers `lake/` en supprimant les PII (nom, prénom, NIR) et en pseudonymisant les identifiants patients
2. Charge les fichiers du lake dans ClickHouse (couche Bronze)
3. Reconstruit les tables nettoyées (couche Silver)
4. Recrée les vues analytiques (couche Gold)

---

## Lancement quotidien (run incrémental)

```bash
cd eds-chu/
python -m pipeline.run
```

Le pipeline détecte automatiquement les nouvelles dates dans `source-filestorage/` et ne recharge pas ce qui est déjà en Bronze.

---

## Configurer Metabase (une seule fois)

Ouvrir **http://localhost:3001**. Metabase prend ~2 minutes à démarrer la première fois.

---

### Étape 1 — Créer le compte administrateur

À la première ouverture, Metabase lance un assistant. Renseigner n'importe quel
email/mot de passe (c'est un compte local). Passer l'étape "Connecter une base de
données" pour l'instant — on le fait manuellement ensuite.

---

### Étape 2 — Ajouter la connexion Pilotage

**Settings** (icône engrenage en haut à droite) → **Admin settings** → **Databases** → **Add a database**

Remplir le formulaire :

| Champ | Valeur |
|---|---|
| Database type | **ClickHouse** |
| Display name | `Pilotage hospitalier` |
| Host | `clickhouse` ⚠️ pas `localhost` — c'est le nom du service Docker |
| Port | `8123` |
| Database name | `gold_pilotage` |
| Username | `default` |
| Password | *(laisser vide)* |

Cliquer **Save** puis **Sync database schema**.

---

### Étape 3 — Ajouter la connexion Recherche

Même chemin : **Databases** → **Add a database**

| Champ | Valeur |
|---|---|
| Database type | **ClickHouse** |
| Display name | `Recherche clinique` |
| Host | `clickhouse` |
| Port | `8123` |
| Database name | `gold_recherche` |
| Username | `default` |
| Password | *(laisser vide)* |

Cliquer **Save** puis **Sync database schema**.

---

### Étape 4 — Créer les groupes d'utilisateurs

**Settings** → **Admin settings** → **People** → **Groups** → **Create a group**

Créer deux groupes :
- `operationnels`
- `chercheurs`

---

### Étape 5 — Restreindre les accès par groupe

**Settings** → **Admin settings** → **Permissions** → onglet **Data**

Pour chaque groupe, cliquer sur la ligne correspondante et configurer :

| Groupe | Base autorisée | Base interdite |
|---|---|---|
| `operationnels` | `Pilotage hospitalier` → **Can view** | `Recherche clinique` → **No self-service** |
| `chercheurs` | `Recherche clinique` → **Can view** | `Pilotage hospitalier` → **No self-service** |

Cliquer **Save changes**.

---

### Étape 6 — Créer les utilisateurs

**Settings** → **Admin settings** → **People** → **Invite someone**

Pour chaque utilisateur, renseigner email + mot de passe, et l'affecter au bon groupe
(`operationnels` ou `chercheurs`). Les membres du groupe `All Users` par défaut ne
doivent avoir accès à aucune des deux bases (mettre **No self-service** partout pour
ce groupe).

---

## Vérifier que tout fonctionne

```sql
-- Dans http://localhost:8123/play

-- Bronze : données brutes chargées
SELECT count() FROM bronze.patients;    -- ~16 200 (3 jours × dump cumulatif)
SELECT count() FROM bronze.sejours;     -- 15 000
SELECT count() FROM bronze.monitoring;  -- ~66 677

-- Silver : après nettoyage
SELECT count() FROM silver.dim_patient;   -- 6 000 patients uniques (dédup)
SELECT count() FROM silver.fact_sejour;   -- 14 864 (15 000 − 136 anomalies)

-- Gold pilotage : KPIs
SELECT * FROM gold_pilotage.v_dms_par_service;
SELECT * FROM gold_pilotage.v_taux_readmission_30j;

-- Gold recherche : cohortes (règle ≥ 5 patients appliquée)
SELECT * FROM gold_recherche.v_prevalence_pathologies;

-- Traçabilité
SELECT * FROM meta.pipeline_runs ORDER BY started_at DESC LIMIT 10;
```

---

## En cas de problemes

**ClickHouse ne démarre pas :**
```bash
docker compose logs clickhouse
docker compose restart clickhouse
```

**Le pipeline échoue en cours de route :**
Le statut `error` est enregistré dans `meta.pipeline_runs`. Relancer simplement `python -m pipeline.run` après avoir corrigé le problème — les dates déjà chargées en Bronze sont ignorées, Silver et Gold sont reconstruits.

**Repartir de zéro (reset complet) :**
```bash
docker compose down -v          # supprime les volumes ClickHouse
rm -rf lake/                    # supprime le lake local
docker compose up -d
python -m pipeline.run
```

> Cela ne touche pas les fichiers source (lecture seule).

**Métabase inaccessible :**
```bash
docker compose logs metabase    # vérifier les erreurs JVM
docker compose restart metabase
```
