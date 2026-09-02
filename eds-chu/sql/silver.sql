-- ===================================================================
-- COUCHE SILVER — Données nettoyées, dédupliquées, enrichies
-- ===================================================================
-- Rôle : appliquer les contrôles qualité et construire les tables
-- dimensionnelles et de faits consommables par la couche Gold.
--
-- Principe architectural clé : TOUTES les transformations métier sont
-- ici, en SQL ClickHouse. Python ne fait qu'envoyer ces requêtes.
--   pandas charge tout en mémoire Python — inefficace sur de gros volumes
--   et difficile à auditer. ClickHouse exécute les transformations côté serveur,
--   directement sur les données stockées, sans transfert réseau inutile.
--
--   Silver n'accumule pas de données, elle transforme. CREATE OR REPLACE TABLE
--   est atomique dans ClickHouse : la nouvelle table remplace l'ancienne en une
--   seule opération. Cela garantit qu'un bug corrigé dans Bronze se répercute
--   immédiatement en Silver, sans résidu de runs précédents. Sur ce volume
--   (<15k séjours), la reconstruction complète prend moins d'une seconde.
--   L'incrémentalité est gérée UNIQUEMENT dans Bronze (meta.pipeline_runs).
--
-- Tables produites :
--   Dimensions : dim_service, dim_pathologie, dim_patient
--   Intermédiaire (suffixe _stg, non exposée en Gold) : sejours_stg (nettoyage)
--   Faits : fact_sejour, fact_diagnostic, fact_monitoring
-- ===================================================================

CREATE DATABASE IF NOT EXISTS silver;

-- -----------------------------------------------------------------
-- Dimension SERVICE
-- -----------------------------------------------------------------
-- bronze.services est un ReplacingMergeTree : ses doublons ne sont pas
-- éliminés immédiatement, seulement lors des merges automatiques ClickHouse.
-- FINAL dans "FROM bronze.services FINAL" force la déduplication à la lecture :
-- Silver reçoit des données déjà propres, sans doublons.
-- La table destination (silver.dim_service) est un MergeTree classique :
-- elle reçoit des données déjà propres, pas besoin de gérer les doublons.
-- On utilise FINAL ici (et pas argMax) car les services n'ont pas de
-- versionnage : il n'y a pas plusieurs valeurs à comparer, juste des
-- doublons éventuels à éliminer. FINAL suffit.
-- Vérification : SELECT count() FROM silver.dim_service → attendu 8
CREATE OR REPLACE TABLE silver.dim_service
ENGINE = MergeTree()
ORDER BY service_code
AS SELECT
    service_code,
    service_label
FROM bronze.services FINAL;

-- -----------------------------------------------------------------
-- Dimension PATHOLOGIE référentiel CIM-10 enrichi du chapitre
-- -----------------------------------------------------------------
-- Le fichier source contient uniquement code + libellé.
-- On dérive le chapitre à partir du premier caractère du code CIM-10,
-- convention internationale
-- Cette colonne n'existe pas dans la source — c'est un enrichissement Silver.
-- Dénormalisé (pas de table chapitre séparée) car le référentiel CIM-10
-- est petit (10 codes ici, 14 000 en réel) et stable : une jointure
-- supplémentaire n'apporterait aucune valeur.
-- Vérification : SELECT code_cim10, chapitre FROM silver.dim_pathologie
--   → chapitre ne doit jamais être 'Autre' pour des codes I**, J**, etc.
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
-- Dimension PATIENT dédupliquée, version la plus récente par patient
-- -----------------------------------------------------------------
-- Le CHU envoie un dump cumulatif chaque jour : 5400/6000 patients
-- apparaissent sur plusieurs jours (confirmé à l'exploration).
-- Bronze contient donc 16 200 lignes pour ~6 000 patients distincts.
-- On garde la version du fichier le plus récent avec argMax(_source_date).
-- argMax(valeur, date) retourne la valeur associée à la date la plus récente.
--   FINAL élimine les doublons mais ne garantit pas quelle version est gardée.
--   argMax est explicite : on choisit délibérément la version la plus récente,
--   ce qui est le comportement correct pour des données cumulatives.
--
-- Contrôle qualité :
--   - sex IN ('M', 'F') : valeurs invalides écartées
--   - patient_pseudo != '' : lignes vides éventuelles écartées
--
-- region_code est inclus ici (nécessaire pour gold_pilotage).
-- gold_recherche exclura region_code dans sa vue (principe de minimisation RGPD).
-- Vérification : SELECT count() FROM silver.dim_patient → doit être < 16 200
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
--
-- Pourquoi une table intermédiaire et pas filtrer directement dans fact_sejour ?
--   sejours_stg est réutilisée par fact_sejour ET fact_diagnostic.
--   Sans elle, il faudrait dupliquer le même filtre WHERE dans deux requêtes,
--   avec le risque qu'elles divergent. Une seule définition = une seule source de vérité.
-- Vérification :
--   SELECT count() FROM bronze.sejours WHERE discharge_ts IS NOT NULL
--     AND discharge_ts < admission_ts  → doit être 136
--   SELECT count() FROM silver.sejours_stg WHERE discharge_ts IS NOT NULL
--     AND discharge_ts < admission_ts  → doit être 0
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
-- Fait SÉJOUR — table centrale du pilotage hospitalier
-- -----------------------------------------------------------------
-- duree_sejour_jours : dateDiff('day', admission_ts, discharge_ts),
--   NULL si discharge_ts est NULL (séjour en cours, durée inconnue).
--
-- Les INDICATEURS MÉTIER (réadmission à 30 jours, alertes de constantes)
-- ne sont PAS calculés ici : Silver nettoie et structure, les règles
-- métier appartiennent à Gold. La réadmission est définie dans
-- gold_pilotage.v_taux_readmission_30j, les seuils cliniques d'alerte
-- dans gold_pilotage.fact_monitoring.
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
-- Fait DIAGNOSTIC — central pour la recherche clinique
-- -----------------------------------------------------------------
-- Grain : 1 ligne par (séjour × code CIM-10).
-- Un séjour peut avoir plusieurs diagnostics (principal + associés).
-- Ce grain permet des requêtes directes par pathologie sans dépiler un tableau.
--
-- INNER JOIN avec sejours_stg :
--   - Récupère patient_pseudo (absent de bronze.diagnostics — le JSON source
--     ne contient que stay_id, pas patient_pseudo)
--   - Écarte automatiquement les diagnostics liés à des séjours invalides
--     (ceux filtrés lors de la construction de sejours_stg)
-- Pourquoi INNER JOIN et pas LEFT JOIN ?
--   Un LEFT JOIN garderait les diagnostics dont le séjour a été écarté en Silver
--   (les 136 incohérents), avec patient_pseudo = NULL. Ces lignes seraient
--   inutilisables et pollueraient les analyses. INNER JOIN = on ne garde que
--   les diagnostics dont on peut garantir la validité du séjour associé.
-- Vérification : SELECT count() FROM silver.fact_diagnostic
--   → doit être inférieur à bronze.diagnostics (37 380)
--
-- age_au_diagnostic :
--   Le JSON source des diagnostics ne porte pas de date propre, la date de
--   référence du diagnostic est la date d'admission du séjour associé.
--   Âge = toYear(admission) - birth_year (jointure sur silver.dim_patient).
--   Approximation à l'année près, correcte pour des statistiques de population
--   (birth_year est déjà généralisé en Bronze pour la pseudonymisation).
--   Calculé ici en Silver pour que Gold n'ait plus qu'à consommer la colonne
--   (ex: tranches d'âge de gold_recherche.v_description_cohorte).
--
-- diagnostic_id = concat(stay_id, '_', code_cim10, '_', type_diag)
--   Clé surrogate stable et reproductible, sans séquence auto-incrémentée
--   (compatible avec le mode de reconstruction total de Silver).
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
-- Fait MONITORING — relevés NETTOYÉS (sans dimensions, sans règle métier)
-- -----------------------------------------------------------------
-- Table de faits autonome : ne joint aucune dimension.
--
-- CONTRÔLE QUALITÉ (rôle de Silver) : les plages du sujet (§3) sont des
-- plages de PLAUSIBILITÉ PHYSIOLOGIQUE, pas des seuils d'alerte clinique :
--   FC    : 20–250 bpm
--   SpO2  : 50–100 %
--   Temp  : 30–45 °C
-- Une valeur hors plage est une donnée ABERRANTE (capteur en panne,
-- valeurs sentinelles 0/500 pour la FC, 0/120 pour la SpO2 observées
-- dans la source) : elle est ÉCARTÉE ici, comme les séjours incohérents
-- le sont dans sejours_stg. Le détail brut reste auditable dans Bronze.
--
-- Les SEUILS D'ALERTE CLINIQUE (SpO2 < 92, FC < 50 ou > 100, Temp > 38,5)
-- sont une règle métier : ils sont définis en Gold
-- (gold_pilotage.fact_monitoring), pas ici.
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
