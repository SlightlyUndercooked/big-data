# Guide de lancement — EDS CHU

## Pré-requis

- Docker + Docker Compose
- Les fichiers source dans `source-filestorage/` (lecture seule, fournis par le CHU)

---

## Premier lancement (une seule fois)

### 1. Configurer l'environnement

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
CRON_SCHEDULE=*/5 * * * *   # toues les 5min
RUN_ON_START=1            # 1 = run dès le démarrage
```

> **Important :** le `PIPELINE_SALT` génère tous les pseudonymes patients. Le changer invalide toutes les jointures existantes.

`SOURCE_DIR` et `LAKE_DIR` restent des chemins **hôte** : Docker les monte dans le conteneur pipeline.

### 2. Télécharger le driver ClickHouse pour Metabase

```bash
curl -L https://github.com/ClickHouse/metabase-clickhouse-driver/releases/download/1.53.4/clickhouse.metabase-driver.jar \
     -o metabase-plugins/clickhouse.metabase-driver.jar
```

### 3. Démarrer la stack

```bash
docker compose up -d --build
```

- ClickHouse : http://localhost:8123/play (interface SQL)
- Metabase : http://localhost:3001 (dashboards) — démarre en ~2 min
- Pipeline : un premier run part tout seul, puis un cron toutes les 5min

Ce que fait le pipeline à chaque run :
1. Copie les fichiers source vers `lake/` en supprimant les PII (nom, prénom, NIR) et en pseudonymisant les identifiants patients
2. Charge les fichiers du lake dans ClickHouse (couche Bronze)
3. Reconstruit les tables nettoyées (couche Silver)
4. Recrée les vues analytiques (couche Gold)

Suivre le premier run :

```bash
docker compose logs -f pipeline
```

---

## Planification (cron)

Le conteneur `pipeline` tourne en permanence tant que la stack est up (`restart: unless-stopped`). Il n'y a rien à relancer à la main.

| Moment | Comportement |
|--------|----------------|
| `docker compose up` | un run immédiat (`RUN_ON_START=1`) |
| Tous les jours à 6 h | cron (`CRON_SCHEDULE`, fuseau `Europe/Paris`) |
| Nouvelle date dans `source-filestorage/` | chargée en Bronze au prochain run ; les dates déjà en `success` sont ignorées |

Forcer un run sans attendre le cron :

```bash
docker compose exec pipeline python -m pipeline.run
```

Un verrou fichier empêche deux runs en parallèle (cron + relance manuelle).

La machine (et Docker) doivent rester allumés : un cron ne tourne pas sur un appareil éteint.

---

## Configurer Metabase (une seule fois)

Voir le guide dédié : **[metabase.md](metabase.md)**

Il couvre : création du compte admin, ajout des deux connexions ClickHouse, groupes d'utilisateurs, permissions, et dépannage du driver ClickHouse.

Une fois le compte admin créé (et ses identifiants renseignés dans `.env`),
les connexions, questions et dashboards se créent automatiquement :

```bash
docker compose exec pipeline python -m pipeline.metabase_setup
```

---

## Vérifier que tout fonctionne

```sql
-- Dans http://localhost:8123/play

-- Bronze : données brutes chargées
SELECT count() FROM bronze.patients;    -- 18 000 (3 photos cumulatives × 6 000)
SELECT count() FROM bronze.sejours;     -- 6 797
SELECT count() FROM bronze.monitoring;  -- 41 778

-- Silver : après nettoyage
SELECT count() FROM silver.dim_patient;   -- 6 000 patients uniques
SELECT count() FROM silver.fact_sejour;   -- 6 729 (6 797 − 68 anomalies)

-- Gold pilotage : KPIs
SELECT * FROM gold_pilotage.v_dms_par_service;
SELECT * FROM gold_pilotage.v_taux_readmission_30j;  -- 780 / 6729 = 11,6 %

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
Le statut `error` est enregistré dans `meta.pipeline_runs`. Relancer après correction :

```bash
docker compose logs pipeline
docker compose exec pipeline python -m pipeline.run
```

Ce que le retry garantit :

- **Source** : intacte (lecture seule)
- **Lake** : fichier déjà copié → skip ; un `.tmp` n'est pas pris pour un fichier fini
- **Bronze** : dates en `success` ignorées ; la date en `error` est d'abord vidée (`DELETE` sur `_source_date`) puis rechargée — pas de doublons
- **Silver / Gold** : reconstruits en entier depuis Bronze

Les dashboards peuvent rester ceux du run précédent jusqu'à ce que Silver et Gold se terminent. Ce n'est pas une corruption, c'est un retard d'un run.

**Repartir de zéro (reset complet) :**
```bash
docker compose down -v          # supprime les volumes ClickHouse
rm -rf lake/                    # supprime le lake local
docker compose up -d --build    # le pipeline se relance tout seul
```

> Cela ne touche pas les fichiers source (lecture seule).

**Métabase inaccessible :**
```bash
docker compose logs metabase    # vérifier les erreurs JVM
docker compose restart metabase
```
