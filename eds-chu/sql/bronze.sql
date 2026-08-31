-- ===================================================================
-- COUCHE BRONZE — Tables typées, données brutes hors PII
-- ===================================================================
-- Rôle : recevoir les fichiers du lake avec le typage SQL correct.
-- Aucune transformation métier ici. Les PII ont déjà été supprimés
-- dans le lake par step0_lake.py (pseudonymisation, suppression NIR/nom/prénom).
--
-- Moteur ClickHouse choisi par table :
--   ReplacingMergeTree : pour les tables avec doublons potentiels (patients,
--     référentiels). Déduplique automatiquement lors des merges ClickHouse.
--     En Silver on force la dédup avec argMax() pour un résultat immédiat.
--   MergeTree classique : pour les tables sans doublons (séjours, diagnostics,
--     monitoring — confirmé à l'exploration des données).
--
-- Traçabilité : chaque ligne porte _source_date (date du fichier) et
-- _ingested_at (horodatage de l'insertion dans ClickHouse).
-- ===================================================================

-- Base de traçabilité du pipeline
CREATE DATABASE IF NOT EXISTS meta;

-- Suivi de chaque run : couche traitée, date source, statut, nb lignes
-- Permet de savoir ce qui a déjà été traité (logique incrémentale) et
-- de produire un audit trail conforme aux exigences de traçabilité RGPD.
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
