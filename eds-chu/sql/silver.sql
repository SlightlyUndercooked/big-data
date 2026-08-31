-- ===================================================================
-- COUCHE SILVER — Données nettoyées, dédupliquées, enrichies
-- ===================================================================
-- Rôle : appliquer les contrôles qualité et construire les tables
-- dimensionnelles et de faits consommables par la couche Gold.
--
-- Principe architectural clé : TOUTES les transformations métier sont
-- ici, en SQL ClickHouse. Python ne fait qu'envoyer ces requêtes
-- (pas de pandas, pas de transformation en mémoire Python).
--
-- Silver est reconstruite entièrement à chaque run du pipeline
-- via CREATE OR REPLACE TABLE (atomique dans ClickHouse).
-- Cela garantit la cohérence : Silver reflète toujours l'état complet
-- de Bronze, sans résidu de runs précédents.
-- L'incrémentalité est gérée UNIQUEMENT en Bronze.
-- ===================================================================

CREATE DATABASE IF NOT EXISTS silver;

-- -----------------------------------------------------------------
-- Dimension TEMPS — calendrier généré, sans source externe
-- -----------------------------------------------------------------
-- Généré en SQL pur avec la fonction numbers() de ClickHouse.
-- 10 ans de dates (2020–2030) couvrent les données actuelles et futures.
-- Partagée entre gold_pilotage et gold_recherche (aucune donnée sensible).
CREATE OR REPLACE TABLE silver.dim_temps
ENGINE = MergeTree()
ORDER BY date_id
AS SELECT
    toDate('2020-01-01') + toUInt32(number)         AS date_id,
    toYear(toDate('2020-01-01')  + toUInt32(number)) AS annee,
    toMonth(toDate('2020-01-01') + toUInt32(number)) AS mois,
    toISOWeek(toDate('2020-01-01') + toUInt32(number)) AS semaine,
    toDayOfWeek(toDate('2020-01-01') + toUInt32(number)) AS jour_semaine_num,
    ['Lundi','Mardi','Mercredi','Jeudi','Vendredi','Samedi','Dimanche']
        [toDayOfWeek(toDate('2020-01-01') + toUInt32(number))] AS jour_semaine
FROM numbers(3650);

-- -----------------------------------------------------------------
-- Dimension SERVICE
-- -----------------------------------------------------------------
-- FINAL force la déduplication ReplacingMergeTree immédiatement,
-- sans attendre le prochain merge automatique de ClickHouse.
CREATE OR REPLACE TABLE silver.dim_service
ENGINE = MergeTree()
ORDER BY service_code
AS SELECT
    service_code,
    service_label
FROM bronze.services FINAL;

-- -----------------------------------------------------------------
-- Dimension PATHOLOGIE — référentiel CIM-10 enrichi du chapitre
-- -----------------------------------------------------------------
-- Le fichier source contient uniquement code + libellé.
-- On dérive le chapitre à partir du premier caractère du code CIM-10,
-- convention internationale (A-B = infectieux, I = circulatoire, etc.).
-- Dénormalisé (pas de table chapitre séparée) car le référentiel CIM-10
-- est petit (~10 codes ici, ~14 000 en réel) et stable.
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
-- Dimension PATIENT — dédupliquée, version la plus récente par patient
-- -----------------------------------------------------------------
-- Le CHU envoie un dump cumulatif chaque jour : 5400/6000 patients
-- apparaissent sur plusieurs jours (confirmé à l'exploration).
-- On garde la version du fichier le plus récent avec argMax(_source_date).
-- argMax(valeur, date) retourne la valeur associée à la date la plus récente.
--
-- Contrôle qualité :
--   - sex IN ('M', 'F') : valeurs invalides écartées
--   - patient_pseudo != '' : lignes vides éventuelles écartées
--
-- region_code est inclus ici (nécessaire pour gold_pilotage).
-- gold_recherche exclura region_code dans sa vue (principe de minimisation RGPD).
CREATE OR REPLACE TABLE silver.dim_patient
ENGINE = MergeTree()
ORDER BY patient_pseudo
-- Sous-requête nécessaire : ClickHouse étend les alias SELECT dans le WHERE,
-- ce qui provoquerait "aggregate function found in WHERE" si on filtrait sex
-- directement dans la requête principale (argMax(sex,...) AS sex serait vu
-- comme une agrégation dans le WHERE). Le filtre est donc appliqué avant
-- l'agrégation, dans un CTE.
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
-- Séjours nettoyés (table intermédiaire Silver, non exposée en Gold)
-- -----------------------------------------------------------------
-- Contrôles qualité appliqués (sujet §3) :
--   ÉCARTÉS  : discharge_ts IS NOT NULL AND discharge_ts <= admission_ts
--              → 136 cas détectés à l'exploration (incohérence temporelle)
--   CONSERVÉS: discharge_ts IS NULL (séjour en cours — valeur légitime)
--   CONSERVÉS: discharge_ts > admission_ts (séjour terminé valide)
CREATE OR REPLACE TABLE silver.sejours_clean
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
-- Agrégation monitoring : alertes par séjour
-- -----------------------------------------------------------------
-- Un relevé est "en alerte" si une constante sort de la plage physiologique.
-- Plages définies dans le sujet (§3 contrôles qualité) :
--   FC    : 20–250 bpm
--   SpO2  : 50–100 %
--   Temp  : 30–45 °C
--
-- Exploration : 1369 alertes sur 66 677 relevés (2,1 %).
--
-- On agrège par séjour pour éviter d'exposer 72k lignes brutes en Gold.
-- Le détail complet reste accessible dans bronze.monitoring pour des
-- analyses ciblées (ex: évolution de la FC d'un patient sur un séjour).
CREATE OR REPLACE TABLE silver.monitoring_alertes
ENGINE = MergeTree()
ORDER BY stay_id
AS SELECT
    stay_id,
    count()  AS nb_mesures,
    countIf(
        heart_rate NOT BETWEEN 20 AND 250
        OR spo2    NOT BETWEEN 50 AND 100
        OR temp_c  NOT BETWEEN 30.0 AND 45.0
    )        AS nb_alertes_monitoring
FROM bronze.monitoring
GROUP BY stay_id;

-- -----------------------------------------------------------------
-- Fait SÉJOUR — table centrale du pilotage hospitalier
-- -----------------------------------------------------------------
-- Indicateurs calculés ici, en SQL ClickHouse (jamais en pandas) :
--
-- 1. duree_sejour_jours :
--    dateDiff('day', admission_ts, discharge_ts)
--    NULL si discharge_ts est NULL (séjour en cours, durée inconnue).
--
-- 2. is_readmission_30j :
--    Calculé par fenêtre glissante avec lagInFrame() de ClickHouse.
--    lagInFrame(discharge_ts, 1, NULL) OVER (PARTITION BY patient_pseudo ORDER BY admission_ts)
--    donne la date de sortie du séjour PRÉCÉDENT du même patient.
--    Si cette sortie précédente existe et a eu lieu entre 1 et 30 jours
--    avant l'admission courante, c'est une réadmission précoce.
--    (BETWEEN 1 AND 30 : exclut 0 jour = le même jour = probablement une mutation)
--
-- 3. nb_alertes_monitoring :
--    Joint depuis silver.monitoring_alertes (calculé ci-dessus).
--    coalesce(..., 0) car certains séjours peuvent ne pas avoir de monitoring.
CREATE OR REPLACE TABLE silver.fact_sejour
ENGINE = MergeTree()
ORDER BY stay_id
AS
WITH prev AS (
    SELECT
        stay_id,
        patient_pseudo,
        service_code,
        admission_ts,
        discharge_ts,
        admission_mode,
        discharge_mode,
        lagInFrame(discharge_ts, 1, NULL) OVER (
            PARTITION BY patient_pseudo
            ORDER BY admission_ts
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS prev_discharge_ts
    FROM silver.sejours_clean
)
SELECT
    stay_id,
    patient_pseudo,
    service_code,
    toDate(admission_ts)  AS date_admission,
    toDate(discharge_ts)  AS date_sortie,
    admission_mode,
    discharge_mode,
    if(
        discharge_ts IS NOT NULL,
        dateDiff('day', admission_ts, discharge_ts),
        NULL
    )                     AS duree_sejour_jours,
    if(
        prev_discharge_ts IS NOT NULL
        AND dateDiff('day', prev_discharge_ts, admission_ts) BETWEEN 1 AND 30,
        1, 0
    )                     AS is_readmission_30j,
    coalesce(m.nb_alertes_monitoring, 0) AS nb_alertes_monitoring
FROM prev
LEFT JOIN silver.monitoring_alertes m USING (stay_id);

-- -----------------------------------------------------------------
-- Fait DIAGNOSTIC — central pour la recherche clinique
-- -----------------------------------------------------------------
-- Grain : 1 ligne par (séjour × code CIM-10).
-- Un séjour peut avoir plusieurs diagnostics (principal + associés).
-- Ce grain permet des requêtes directes par pathologie sans dépiler un tableau.
--
-- INNER JOIN avec sejours_clean :
--   - Récupère patient_pseudo (absent de bronze.diagnostics)
--   - Écarte automatiquement les diagnostics liés à des séjours invalides
--     (ceux filtrés lors de la construction de sejours_clean)
--
-- diagnostic_id = concat(stay_id, '_', code_cim10, '_', type_diag)
--   Clé surrogate stable et reproductible, sans séquence auto-incrémentée
--   (compatible avec le mode de reconstruction total de Silver).
CREATE OR REPLACE TABLE silver.fact_diagnostic
ENGINE = MergeTree()
ORDER BY (code_cim10, patient_pseudo, stay_id)
AS SELECT
    concat(d.stay_id, '_', d.code_cim10, '_', d.type_diag) AS diagnostic_id,
    s.patient_pseudo,
    d.code_cim10,
    d.stay_id,
    toDate(s.admission_ts) AS date_admission,
    d.type_diag,
    s.service_code
FROM bronze.diagnostics d
INNER JOIN silver.sejours_clean s ON d.stay_id = s.stay_id
