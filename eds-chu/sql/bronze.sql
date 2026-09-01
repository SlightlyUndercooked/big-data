-- ===================================================================
-- COUCHE BRONZE — Tables typées, données brutes hors PII
-- ===================================================================
-- Rôle : recevoir les fichiers du lake avec le typage SQL correct.
-- Aucune transformation métier ici. Les PII ont déjà été supprimés
-- dans le lake par step0_lake.py (pseudonymisation, suppression NIR/nom/prénom).
--
-- Pourquoi ClickHouse et pas PostgreSQL ?
--   ClickHouse est une base de données COLONNE : les données sont stockées
--   par colonne et non par ligne. Pour l'analytique (SELECT avg(duree_sejour)
--   sur 15 000 séjours), ClickHouse ne lit que la colonne concernée au lieu
--   de lire toutes les lignes entières. Gain de performance majeur + compression
--   native très efficace sur les données répétitives (codes, dates, catégories).
--
-- Moteur ClickHouse choisi par table :
--   ReplacingMergeTree seulement pour les tables où les doublons sont confirmés
--     par l'exploration des données (patients, référentiels). Le chu renvoie un
--     dump complet chaque jour, les mêmes patients apparaissent dans plusieurs
--     fichiers. ReplacingMergeTree déduplique sur la clé ORDER BY lors des merges.
--     la déduplication n'est pas immédiate, elle attend le prochain
--     merge automatique. Pour forcer une lecture dédupliquée immédiatement,
--     il faut utiliserFINAL ou argMax()
--   MergeTree classique : pour les tables sans doublons (séjours, diagnostics,
--     monitoring confirmé à l'exploration : aucun stay_id commun entre les 3 jours).
--
--     ReplacingMergeTree consomme plus de cpu et de disque à
--     l'insertion pour gérer la déduplication en arrière plan
--
-- Pourquoi _source_date sur chaque ligne ?
--   Bronze mélange les données de 3 jours dans la même table. Sans _source_date,
--   impossible de savoir de quel fichier vient une ligne, ni d'auditer le chargement.
--   C'est aussi la clé de l'incrémentalité : meta.pipeline_runs trace les dates
--   déjà chargées, et _source_date permet de vérifier la cohérence.
--
-- Principe fondamental : Bronze ne filtre rien.
--   Les 136 séjours avec discharge < admission et les 1190 séjours en cours
--   sont tous conservés. Filtrer en Bronze ferait perdre la traçabilité des
--   anomalies — on ne pourrait plus auditer leur origine ni les corriger si
--   le CHU envoie un fichier corrigé. Les filtres métier appartiennent à Silver.
-- ===================================================================

-- Base de traçabilité du pipeline
CREATE DATABASE IF NOT EXISTS meta;

-- Suivi de chaque run : couche traitée, date source, statut, nb lignes.
--
-- Pourquoi cette table et pas un simple COUNT() sur bronze.patients ?
--   Un COUNT() serait coûteux et peu fiable : si le chargement plante à mi-chemin,
--   des lignes existent déjà et on ne saurait pas si la date est complète ou partielle.
--   pipeline_runs est une table légère, indexée sur (layer, source_date), qui stocke
--   explicitement le statut de chaque run. Un statut 'error' = réessaie au prochain run.
--   Un statut 'success' = saute cette date. C'est aussi un audit trail RGPD :
--   on sait exactement ce qui a été inséré, quand, et combien de lignes.
CREATE TABLE IF NOT EXISTS meta.pipeline_runs (
    run_id         UUID     DEFAULT generateUUIDv4(),
    layer          String,                   -- 'bronze' | 'silver' | 'gold'
    source_date    String,                   -- 'YYYY-MM-DD' ou 'referentiels'
    status         String,                   -- 'success' | 'error'
    started_at     DateTime DEFAULT now(),
    finished_at    Nullable(DateTime),
    rows_processed UInt32   DEFAULT 0,
    error_msg      Nullable(String)
) ENGINE = MergeTree()
  ORDER BY (layer, source_date, started_at);

-- Base Bronze
CREATE DATABASE IF NOT EXISTS bronze;

-- -----------------------------------------------------------------
-- Patients : dumps quotidiens cumulatifs
-- -----------------------------------------------------------------
-- Exploration des données révèle que 5400/6000 patients apparaissent
-- sur plusieurs jours (le CHU renvoie le fichier complet chaque jour).
-- ReplacingMergeTree(_ingested_at) garde la version la plus récente
-- lors des merges ClickHouse. En Silver, on utilise argMax() pour
-- forcer la déduplication immédiate sans attendre le merge.
--
-- PII supprimés par step0 : patient_id, nom, prenom, nir, birth_date.
-- Seuls birth_year (généralisation) et region_code (non-direct) restent.
CREATE TABLE IF NOT EXISTS bronze.patients (
    patient_pseudo  String,                      -- HMAC-SHA256(patient_id, sel)
    birth_year      UInt16,                      -- année de naissance uniquement
    sex             LowCardinality(String),      -- 'M' ou 'F' (normalisé step0)
    region_code     LowCardinality(String),      -- département de résidence
    _source_date    Date,                        -- date du fichier source
    _ingested_at    DateTime DEFAULT now()
) ENGINE = ReplacingMergeTree(_ingested_at)
  ORDER BY (patient_pseudo, _source_date);

-- -----------------------------------------------------------------
-- Séjours : un fichier par jour, sans chevauchement entre les jours
-- -----------------------------------------------------------------
-- Exploration : aucun stay_id commun entre les 3 jours → pas de doublon.
-- MergeTree classique suffit.
-- discharge_ts est Nullable : NULL = séjour en cours (patient encore hospitalisé).
-- C'est une valeur LÉGITIME, pas une anomalie (sujet §3 contrôles qualité).
CREATE TABLE IF NOT EXISTS bronze.sejours (
    stay_id         String,
    patient_pseudo  String,                      -- déjà pseudonymisé dans le lake
    service_code    LowCardinality(String),
    admission_ts    DateTime,
    discharge_ts    Nullable(DateTime),          -- NULL = séjour en cours
    admission_mode  LowCardinality(String),      -- urgence | programme | mutation
    discharge_mode  String,                      -- vide si pas encore de sortie
    _source_date    Date,
    _ingested_at    DateTime DEFAULT now()
) ENGINE = MergeTree()
  ORDER BY (stay_id);

-- -----------------------------------------------------------------
-- Diagnostics : dépliés depuis le JSON imbriqué
-- -----------------------------------------------------------------
-- Structure source : [{"stay_id": "S00000001", "diagnostics": [...]}]
-- Step1 déplie en Python : 1 ligne par (stay_id, code_cim10, type_diag).
-- Un séjour peut avoir plusieurs diagnostics (principal + associés).
--
-- Pourquoi le dépliage en Python et pas en SQL ?
--   ClickHouse peut parser du JSON mais le faire en Python est plus lisible
--   et plus simple à maintenir. La double boucle Python (séjour → diagnostics)
--   est naturelle pour aplatir cette structure imbriquée. Le résultat inséré
--   est déjà au bon grain pour toutes les couches suivantes : 1 ligne = 1 code.
--
--   MergeTree est le moteur de base de ClickHouse : il stocke les données triées
--   sur disque et les fusionne en arrière-plan pour optimiser les lectures.
--   Pas de gestion des doublons. On choisit MergeTree au lieu deReplacingMergeTree
--   parce que l'exploration des données confirme qu'il n'y a aucun doublon
--   dans les diagnostics entre les 3 jours : chaque (stay_id, code_cim10, type_diag)
--   n'apparaît qu'une seule fois.
--
-- ORDER BY (stay_id, code_cim10, type_diag) définit l'ordre de stockage physique sur disque l'équivalent d'un index primaire
--   intégré dans la structure de stockage. Les requêtes typiques sur les diagnostics
--   filtrent toujours par séjour en premier (WHERE stay_id = ...), puis éventuellement
--   par code ou type. ClickHouse sait alors exactement dans quel bloc chercher
--   sans scanner toute la table.
CREATE TABLE IF NOT EXISTS bronze.diagnostics (
    stay_id      String,
    code_cim10   String,
    type_diag    LowCardinality(String),         -- 'principal' | 'associe'
    _source_date Date,
    _ingested_at DateTime DEFAULT now()
) ENGINE = MergeTree()
  ORDER BY (stay_id, code_cim10, type_diag);

-- -----------------------------------------------------------------
-- Monitoring : flux haute fréquence (constantes au chevet)
-- -----------------------------------------------------------------
-- ~24 000 relevés par jour, ~72 000 sur 3 jours.
-- MergeTree avec ORDER BY (stay_id, ts) pour des lectures rapides
-- par patient (filtre sur stay_id) ou par tranche horaire (filtre sur ts).
-- Les valeurs hors plage physiologique sont détectées en Silver
-- (on ne filtre pas en Bronze pour conserver la traçabilité des anomalies).
--
-- Pourquoi insert_arrow pour cette table (et pas les autres) ?
--   Le fichier source est en Parquet. PyArrow le lit nativement en mémoire
--   sous forme de Table Arrow. insert_arrow envoie cette table directement
--   à ClickHouse via le protocole binaire natif, sans conversion intermédiaire
--   vers des listes Python. C'est la méthode la plus rapide pour les gros volumes.
--   Les CSV n'ont pas d'équivalent natif Arrow → on passe par des listes Python.
CREATE TABLE IF NOT EXISTS bronze.monitoring (
    stay_id      String,
    ts           DateTime,
    heart_rate   Int32,      -- bpm — plage normale : 20–250
    spo2         Int32,      -- %   — plage normale : 50–100
    temp_c       Float32,    -- °C  — plage normale : 30–45
    _source_date Date,
    _ingested_at DateTime DEFAULT now()
) ENGINE = MergeTree()
  ORDER BY (stay_id, ts);

-- -----------------------------------------------------------------
-- Référentiels : services et CIM-10
-- -----------------------------------------------------------------
-- Déposés une seule fois par le CHU (J0).
-- ReplacingMergeTree pour idempotence (si rechargés, pas de doublon).
CREATE TABLE IF NOT EXISTS bronze.services (
    service_code  String,
    service_label String,
    _ingested_at  DateTime DEFAULT now()
) ENGINE = ReplacingMergeTree(_ingested_at)
  ORDER BY service_code;

CREATE TABLE IF NOT EXISTS bronze.cim10 (
    code_cim10   String,
    libelle      String,
    _ingested_at DateTime DEFAULT now()
) ENGINE = ReplacingMergeTree(_ingested_at)
  ORDER BY code_cim10
