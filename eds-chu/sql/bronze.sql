-- ===================================================================
-- COUCHE BRONZE — Tables typées, données brutes hors PII
-- ===================================================================
-- Aucune transformation métier. Les PII ont déjà été retirés dans le
-- lake (step0). Bronze ne filtre rien : les anomalies restent
-- auditables ; les contrôles qualité sont en Silver.
--
-- Moteurs :
--   ReplacingMergeTree : patients et référentiels (dumps cumulatifs /
--     rechargements). La dédup n'est pas immédiate : Silver lit avec
--     FINAL ou argMax.
--   MergeTree : séjours, diagnostics, monitoring (pas de doublons
--     attendus entre fichiers journaliers).
--
-- _source_date : provenance du fichier, et clé de l'incrémentalité
-- avec meta.pipeline_runs.
-- ===================================================================

-- Base de traçabilité du pipeline
CREATE DATABASE IF NOT EXISTS meta;

-- Suivi de chaque run Bronze. Un COUNT() sur les tables cibles ne
-- distingue pas un chargement complet d'un crash à mi-chemin.
-- 'success' → skip ; 'error' → retry. source_date = 'referentiels'
-- pour le chargement unique des nomenclatures.
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
-- Patients
-- -----------------------------------------------------------------
-- Dump cumulatif : ReplacingMergeTree(_ingested_at). Silver force avec argMax.
CREATE TABLE IF NOT EXISTS bronze.patients (
    patient_pseudo  String,                      -- HMAC-SHA256(patient_id, sel)
    birth_year      UInt16,                      -- année de naissance uniquement
    sex             LowCardinality(String),      -- 'M' ou 'F' (normalisé step0)
    region_code     LowCardinality(String),      -- département de résidence
    _source_date    Date,
    _ingested_at    DateTime DEFAULT now()
) ENGINE = ReplacingMergeTree(_ingested_at)
  ORDER BY (patient_pseudo, _source_date);

-- -----------------------------------------------------------------
-- Séjours
-- -----------------------------------------------------------------
-- Un fichier par jour, pas de stay_id partagé attendu → MergeTree.
-- discharge_ts NULL = séjour en cours (valeur légitime).
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
-- JSON source déplié en Python (step1) : 1 ligne = 1 code CIM-10.
-- MergeTree : pas de doublons attendus entre fichiers journaliers.
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
-- Relevés haute fréquence. Hors-plage physiologique conservés ici
-- (filtre Silver). Chargement via insert_arrow (step1).
CREATE TABLE IF NOT EXISTS bronze.monitoring (
    stay_id      String,
    ts           DateTime,
    heart_rate   Int32,      -- bpm
    spo2         Int32,      -- %
    temp_c       Float32,    -- °C
    _source_date Date,
    _ingested_at DateTime DEFAULT now()
) ENGINE = MergeTree()
  ORDER BY (stay_id, ts);

-- -----------------------------------------------------------------
-- Référentiels : services et CIM-10
-- -----------------------------------------------------------------
-- Nomenclatures déposées une fois. ReplacingMergeTree = rechargement
-- sans doublon après merge.
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
