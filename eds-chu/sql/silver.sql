-- ===================================================================
-- COUCHE SILVER — Qualité, dédup, enrichissement
-- ===================================================================
-- Transformations en SQL (CREATE OR REPLACE, reconstruction totale).
-- L'incrémentalité est uniquement en Bronze.
--
-- Qualité seulement : pas de réadmission, pas d'alertes cliniques
-- (règles métier → Gold).
--
-- Dimensions : dim_service, dim_pathologie, dim_patient, dim_ccam
-- Intermédiaire : sejours_stg (non exposée)
-- Faits : fact_sejour, fact_diagnostic, fact_monitoring, fact_acte
--
-- Évolution 2026-08-29 : dim_service enrichie (categorie / pole /
-- capacite_lits), + dim_ccam et fact_acte.
-- ===================================================================

CREATE DATABASE IF NOT EXISTS silver;

-- -----------------------------------------------------------------
-- Dimension SERVICE — enrichie par le dépôt 2026-08-29
-- -----------------------------------------------------------------
-- FINAL : force la dédup ReplacingMergeTree à la lecture (pas d'argMax :
-- les services n'ont pas de versions à départager).
--
-- Hiérarchie d'agrégation croissante ajoutée par description_service :
--   service_label (1 par service) -> categorie -> pole
-- Elle permet d'analyser à trois niveaux, ce n'est pas de la redondance.
--
-- LEFT JOIN, ET NON INNER — DÉCISION STRUCTURANTE
--   description_service.csv ne décrit que 7 services sur 8 : NEURO est
--   absent du référentiel. Un INNER JOIN le ferait disparaître de la
--   dimension, et avec lui 1 208 séjours (18 % de l'activité) de tous
--   les KPI par catégorie — silencieusement, sans erreur ni ligne vide.
--   Le LEFT JOIN garantit que la dimension reste alignée sur la liste
--   de référence des services (bronze.services), quoi qu'il manque
--   dans le référentiel descriptif.
--
-- REPLI SUR LES ÉTIQUETTES, NULL SUR LA MESURE
--   categorie et pole : 'non renseigne'. Ce sont des libellés de
--   regroupement — un GROUP BY sur NULL produirait une ligne sans nom,
--   illisible en dashboard. Le repli explicite rend le trou VISIBLE,
--   ce qui en fait un signal de qualité de donnée poussant le CHU à
--   compléter son référentiel, au lieu de l'enterrer.
--   capacite_lits : laissée NULL, surtout pas coalesce(..., 0). Zéro lit
--   provoquerait une division par zéro dans la densité d'actes par lit,
--   ou pire une valeur aberrante qui RESSEMBLE à un vrai chiffre. NULL
--   se propage honnêtement : la case reste vide pour NEURO.
--   Règle appliquée : on remplit les étiquettes, jamais les mesures.
--
-- Vérification : SELECT count() FROM silver.dim_service -> 8 (pas 7)
CREATE OR REPLACE TABLE silver.dim_service
ENGINE = MergeTree()
ORDER BY service_code
AS SELECT
    s.service_code,
    s.service_label,
    coalesce(nullIf(d.categorie, ''), 'non renseigne') AS categorie,
    coalesce(nullIf(d.pole, ''),      'non renseigne') AS pole,
    -- capacite_lits est UInt16 NON nullable côté Bronze : sur un LEFT JOIN
    -- non apparié ClickHouse le remplit avec le défaut du type, soit 0 —
    -- précisément la valeur piégeuse qu'on veut éviter. On teste donc
    -- l'échec de jointure (service_code vide) pour forcer un vrai NULL.
    if(d.service_code = '', NULL, d.capacite_lits)      AS capacite_lits,
    -- Drapeau explicite : permet de filtrer ou de compter les services
    -- non décrits sans avoir à tester la chaîne 'non renseigne'.
    toUInt8(d.service_code = '')                       AS description_manquante
FROM bronze.services AS s FINAL
LEFT JOIN bronze.description_service AS d FINAL
    ON s.service_code = d.service_code;

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
;

-- -----------------------------------------------------------------
-- ÉVOLUTION — Dimension CCAM (nomenclature des actes)
-- -----------------------------------------------------------------
-- FINAL : dédup ReplacingMergeTree à la lecture, comme dim_service.
-- tarif_euros est porté par la DIMENSION, pas par le fait : le tarif est
-- un attribut du type d'acte, identique pour toutes ses occurrences.
-- Le montant facturé se calcule donc par jointure, sans dupliquer le
-- tarif sur 8 112 lignes de faits.
CREATE OR REPLACE TABLE silver.dim_ccam
ENGINE = MergeTree()
ORDER BY code_ccam
AS SELECT
    code_ccam,
    libelle,
    tarif_euros
FROM bronze.ccam FINAL;

-- -----------------------------------------------------------------
-- ÉVOLUTION — Fait ACTE
-- -----------------------------------------------------------------
-- Grain : un acte médical réalisé pendant un séjour.
--
-- DÉNORMALISATION DE service_code — DÉCISION STRUCTURANTE
--   La source ne porte que stay_id : le service est un attribut du
--   SÉJOUR, pas de l'acte. Trois KPI en ont pourtant besoin (actes par
--   service, densité par lit, montant T2A par service).
--   La tentation serait de joindre fact_acte à fact_sejour au moment de
--   la requête. C'est un anti-pattern : ce sont deux faits de GRAINS
--   DIFFÉRENTS (un acte vs un séjour). Les joindre crée un fan trap —
--   chaque séjour est dupliqué autant de fois qu'il a d'actes. Sommer
--   tarif_euros resterait juste, mais toute mesure du séjour
--   (duree_sejour_jours...) serait multipliée par le nombre d'actes,
--   silencieusement.
--   On rapatrie donc service_code ICI, à la construction. fact_acte ne
--   joint plus ensuite que des DIMENSIONS (dim_service, dim_ccam) :
--   une étoile propre, sans piège de grain possible côté dashboard.
--   C'est exactement ce que fait déjà fact_diagnostic pour récupérer
--   patient_pseudo et service_code — cohérence, pas invention.
--
-- INNER JOIN sur sejours_stg :
--   écarte les actes dont le séjour est inconnu ou a été rejeté pour
--   incohérence temporelle : 82 actes (1 %) portés par 51 séjours
--   orphelins. Même traitement que les diagnostics orphelins.
--
-- date_acte : dérivée de acte_ts, JAMAIS de _source_date. Le dépôt du
--   2026-08-29 contient des actes du 1er au 29 août : grouper sur la
--   date de dépôt écraserait un mois d'activité sur une seule journée.
--
-- Vérification :
--   SELECT count() FROM silver.fact_acte  -> 8112 - 82 = 8030
CREATE OR REPLACE TABLE silver.fact_acte
ENGINE = MergeTree()
ORDER BY (service_code, code_ccam, stay_id)
AS SELECT
    a.stay_id                AS stay_id,
    a.code_ccam              AS code_ccam,
    a.acte_ts                AS acte_ts,
    toDate(a.acte_ts)        AS date_acte,
    s.service_code           AS service_code,
    s.patient_pseudo         AS patient_pseudo
FROM bronze.actes a
INNER JOIN silver.sejours_stg s ON a.stay_id = s.stay_id
