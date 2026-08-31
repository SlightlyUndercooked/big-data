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

Voir le guide dédié : **[docs/metabase.md](metabase.md)**

Il couvre : création du compte admin, ajout des deux connexions ClickHouse, groupes d'utilisateurs, permissions, et dépannage du driver ClickHouse.

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
