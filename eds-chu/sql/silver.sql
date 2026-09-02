-- ===================================================================
-- COUCHE SILVER — Qualité, dédup, enrichissement
-- ===================================================================
-- Transformations en SQL (CREATE OR REPLACE, reconstruction totale).
-- L'incrémentalité est uniquement en Bronze.
--
-- Qualité seulement : pas de réadmission, pas d'alertes cliniques
-- (règles métier → Gold).
--
-- Dimensions : dim_service, dim_pathologie, dim_patient
-- Intermédiaire : sejours_stg (non exposée)
-- Faits : fact_sejour, fact_diagnostic, fact_monitoring
-- ===================================================================

CREATE DATABASE IF NOT EXISTS silver;

-- -----------------------------------------------------------------
-- Dimension SERVICE
-- -----------------------------------------------------------------
-- FINAL : force la dédup ReplacingMergeTree à la lecture (pas d'argMax :
-- les services n'ont pas de versions à départager).
CREATE OR REPLACE TABLE silver.dim_service
ENGINE = MergeTree()
ORDER BY service_code
AS SELECT
    service_code,
    service_label
FROM bronze.services FINAL;

-- -----------------------------------------------------------------
-- Dimension PATHOLOGIE — chapitre dérivé du 1er caractère CIM-10
-- -----------------------------------------------------------------
-- Dénormalisé (référentiel petit et stable, pas de table chapitre).
CREATE OR REPLACE TABLE silver.dim_pathologie
ENGINE = MergeTree()
ORDER BY code_cim10
AS SELECT
    code_cim10,
    libelle,
    CASE upper(substring(code_cim10, 1, 1))
        WHEN 'A' THEN 'Maladies infectieuses et parasitaires'
        WHEN 'B' THEN 'Maladies infectieuses et parasitaires'
        WHEN 'C' THEN 'Tumeurs'
        WHEN 'D' THEN 'Maladies du sang et troubles immunitaires'
        WHEN 'E' THEN 'Maladies endocriniennes et métaboliques'
        WHEN 'F' THEN 'Troubles mentaux et du comportement'
        WHEN 'G' THEN 'Maladies du système nerveux'
        WHEN 'H' THEN 'Maladies de l''oeil et de l''oreille'
        WHEN 'I' THEN 'Maladies de l''appareil circulatoire'
        WHEN 'J' THEN 'Maladies de l''appareil respiratoire'
        WHEN 'K' THEN 'Maladies de l''appareil digestif'
        WHEN 'L' THEN 'Maladies de la peau'
        WHEN 'M' THEN 'Maladies ostéo-articulaires'
        WHEN 'N' THEN 'Maladies de l''appareil génito-urinaire'
        WHEN 'O' THEN 'Grossesse, accouchement et puerpéralité'
        WHEN 'P' THEN 'Affections périnatales'
        WHEN 'Q' THEN 'Malformations congénitales'
        WHEN 'R' THEN 'Symptômes et signes anormaux'
        WHEN 'S' THEN 'Traumatismes et causes externes'
        WHEN 'T' THEN 'Traumatismes et causes externes'
        WHEN 'U' THEN 'Codes à usage spécial'
        WHEN 'Z' THEN 'Facteurs influençant l''état de santé'
        ELSE 'Autre'
    END AS chapitre
FROM bronze.cim10 FINAL;

-- -----------------------------------------------------------------
-- Dimension PATIENT — dump cumulatif : on garde la photo la plus récente
-- -----------------------------------------------------------------
-- argMax(_source_date) plutôt que FINAL : FINAL déduplique sans garantir
-- quelle version survit. Filtre sex / pseudo vide avant agrégation.
--
-- CTE obligatoire : ClickHouse étend les alias SELECT dans le WHERE,
-- donc un WHERE sex IN (...) après argMax(sex, ...) AS sex lèverait
-- "aggregate function found in WHERE".
--
-- region_code reste ici ; Gold recherche ne l'expose pas.
CREATE OR REPLACE TABLE silver.dim_patient
ENGINE = MergeTree()
ORDER BY patient_pseudo
AS
WITH base AS (
    SELECT * FROM bronze.patients
    WHERE patient_pseudo != ''
      AND sex IN ('M', 'F')
)
SELECT
    patient_pseudo,
    argMax(birth_year,  _source_date) AS birth_year,
    argMax(sex,         _source_date) AS sex,
    argMax(region_code, _source_date) AS region_code
FROM base
GROUP BY patient_pseudo;

-- -----------------------------------------------------------------
-- Séjours nettoyés (intermédiaire, non exposée)
-- -----------------------------------------------------------------
-- Écartés : discharge_ts <= admission_ts (incohérence).
-- Conservés : discharge_ts NULL (séjour en cours) et sorties valides.
-- Table partagée par fact_sejour et fact_diagnostic : un seul filtre.
CREATE OR REPLACE TABLE silver.sejours_stg
ENGINE = MergeTree()
ORDER BY stay_id
AS SELECT
    stay_id,
    patient_pseudo,
    service_code,
    admission_ts,
    discharge_ts,
    admission_mode,
    discharge_mode
FROM bronze.sejours
WHERE discharge_ts IS NULL
   OR discharge_ts > admission_ts;

-- -----------------------------------------------------------------
-- Fait SÉJOUR
-- -----------------------------------------------------------------
-- duree_sejour_jours NULL si séjour en cours.
-- Réadmission et alertes cliniques : Gold, pas ici.
CREATE OR REPLACE TABLE silver.fact_sejour
ENGINE = MergeTree()
ORDER BY stay_id
AS SELECT
    stay_id,
    patient_pseudo,
    service_code,
    admission_ts,
    discharge_ts,
    toDate(admission_ts)  AS date_admission,
    toDate(discharge_ts)  AS date_sortie,
    admission_mode,
    discharge_mode,
    if(
        discharge_ts IS NOT NULL,
        dateDiff('day', admission_ts, discharge_ts),
        NULL
    )                     AS duree_sejour_jours
FROM silver.sejours_stg;

-- -----------------------------------------------------------------
-- Fait DIAGNOSTIC — 1 ligne par (séjour × code CIM-10)
-- -----------------------------------------------------------------
-- INNER JOIN sejours_stg : récupère patient_pseudo (absent du JSON) et
-- écarte les diagnostics d'un séjour invalide. LEFT JOIN laisserait
-- patient_pseudo NULL sur ces lignes.
--
-- age_au_diagnostic = année d'admission − birth_year (le JSON n'a pas
-- de date propre). diagnostic_id = concat stable, sans séquence.
CREATE OR REPLACE TABLE silver.fact_diagnostic
ENGINE = MergeTree()
ORDER BY (code_cim10, patient_pseudo, stay_id)
AS SELECT
    concat(d.stay_id, '_', d.code_cim10, '_', d.type_diag) AS diagnostic_id,
    s.patient_pseudo AS patient_pseudo,
    d.code_cim10 AS code_cim10,
    d.stay_id AS stay_id,
    toDate(s.admission_ts) AS date_admission,
    toYear(s.admission_ts) - p.birth_year AS age_au_diagnostic,
    d.type_diag AS type_diag,
    s.service_code AS service_code
FROM bronze.diagnostics d
INNER JOIN silver.sejours_stg s ON d.stay_id = s.stay_id
INNER JOIN silver.dim_patient p ON s.patient_pseudo = p.patient_pseudo;

-- -----------------------------------------------------------------
-- Fait MONITORING — plausibilité physiologique, pas d'alerte clinique
-- -----------------------------------------------------------------
-- FC 20–250, SpO2 50–100, Temp 30–45 : hors plage = capteur / sentinelle
-- (0, 500…), écarté. Seuils cliniques (SpO2 < 92, etc.) → Gold.
CREATE OR REPLACE TABLE silver.fact_monitoring
ENGINE = MergeTree()
ORDER BY (stay_id, ts)
AS SELECT
    stay_id,
    ts,
    toDate(ts)  AS date_mesure,
    heart_rate,
    spo2,
    temp_c
FROM bronze.monitoring
WHERE heart_rate BETWEEN 20 AND 250
  AND spo2 BETWEEN 50 AND 100
  AND temp_c BETWEEN 30.0 AND 45.0
