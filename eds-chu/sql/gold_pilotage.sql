-- ===================================================================
-- COUCHE GOLD — PILOTAGE HOSPITALIER
-- ===================================================================
-- Audience : opérationnels. Compte ClickHouse eds_pilotage (step4).
--
-- dim_patient partagée avec gold_recherche (pseudo, birth_year, sex).
-- region_code est dénormalisé dans fact_sejour (attribut d'admission,
-- pas un attribut stable du patient).
--
-- Les FACTS lisent Silver. Les vues KPI ne lisent que Gold.
--
-- SQL SECURITY DEFINER : par défaut une vue s'exécute avec les droits
-- de l'appelant. eds_pilotage n'a aucun droit sur silver. DEFINER
-- exécute la vue avec les droits du créateur (admin pipeline) : la
-- projection est la frontière, les colonnes absentes sont inatteignables.
-- ===================================================================

CREATE DATABASE IF NOT EXISTS gold_pilotage;

-- Même projection que gold_recherche. region_code : fact_sejour.
CREATE OR REPLACE VIEW gold_pilotage.dim_patient
DEFINER = CURRENT_USER SQL SECURITY DEFINER
AS SELECT
    patient_pseudo,
    birth_year,
    sex
FROM silver.dim_patient;

CREATE OR REPLACE VIEW gold_pilotage.dim_service
DEFINER = CURRENT_USER SQL SECURITY DEFINER
AS SELECT * FROM silver.dim_service;


-- Seuils cliniques (Silver n'a fait que la plausibilité) :
--   SpO2 < 92 | FC < 50 ou > 100 | Temp > 38,5
-- is_alerte = au moins un des trois.
-- service_code via INNER JOIN : un relevé dont le séjour a été écarté
-- en Silver n'entre pas dans le mart.
CREATE OR REPLACE VIEW gold_pilotage.fact_monitoring
DEFINER = CURRENT_USER SQL SECURITY DEFINER
AS SELECT
    m.stay_id,
    s.service_code,
    m.ts,
    m.date_mesure,
    m.heart_rate,
    m.spo2,
    m.temp_c,
    toUInt8(m.spo2 < 92) AS alerte_desaturation,
    toUInt8(m.heart_rate < 50 OR m.heart_rate > 100) AS alerte_brady_tachycardie,
    toUInt8(m.temp_c > 38.5) AS alerte_fievre,
    toUInt8(
        m.spo2 < 92
        OR m.heart_rate < 50 OR m.heart_rate > 100
        OR m.temp_c > 38.5
    ) AS is_alerte
FROM silver.fact_monitoring m
INNER JOIN silver.fact_sejour s ON m.stay_id = s.stay_id;

-- region_code dénormalisé depuis silver.dim_patient.
-- is_readmission_30j : lagInFrame, fenêtre 1–30 jours (le même jour =
-- mutation, pas une réadmission).
-- nb_alertes_monitoring : SUM(is_alerte) sur fact_monitoring (un seul
-- endroit où les seuils sont écrits).
CREATE OR REPLACE VIEW gold_pilotage.fact_sejour
DEFINER = CURRENT_USER SQL SECURITY DEFINER
AS
WITH alertes_par_sejour AS (
    SELECT
        stay_id,
        sum(is_alerte) AS nb_alertes_monitoring
    FROM gold_pilotage.fact_monitoring
    GROUP BY stay_id
)
SELECT
    f.stay_id,
    f.patient_pseudo,
    f.service_code,
    f.date_admission,
    f.date_sortie,
    f.admission_mode,
    f.discharge_mode,
    f.duree_sejour_jours,
    if(
        lagInFrame(f.discharge_ts, 1, NULL) OVER w IS NOT NULL
        AND dateDiff('day', lagInFrame(f.discharge_ts, 1, NULL) OVER w, f.admission_ts)
            BETWEEN 1 AND 30,
        1, 0
    ) AS is_readmission_30j,
    coalesce(a.nb_alertes_monitoring, 0) AS nb_alertes_monitoring,
    p.region_code
FROM silver.fact_sejour f
LEFT JOIN alertes_par_sejour a USING (stay_id)
LEFT JOIN silver.dim_patient p USING (patient_pseudo)
WINDOW w AS (
    PARTITION BY f.patient_pseudo
    ORDER BY f.admission_ts
    ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
);

-- -----------------------------------------------------------------
-- KPI 1 : Durée Moyenne de Séjour (DMS) par service
-- -----------------------------------------------------------------
CREATE OR REPLACE VIEW gold_pilotage.v_dms_par_service
DEFINER = CURRENT_USER SQL SECURITY DEFINER
AS SELECT
    f.service_code,
    s.service_label,
    round(avg(f.duree_sejour_jours), 1) AS dms_jours,
    count()                             AS nb_sejours_termines,
    countIf(f.duree_sejour_jours > 30)  AS nb_longs_sejours
FROM gold_pilotage.fact_sejour f
LEFT JOIN gold_pilotage.dim_service s ON f.service_code = s.service_code
WHERE f.date_sortie IS NOT NULL
GROUP BY f.service_code, s.service_label
ORDER BY dms_jours DESC;

-- -----------------------------------------------------------------
-- KPI 1bis : DMS par service et par mois
-- -----------------------------------------------------------------
-- Mois de SORTIE : la durée n'est connue qu'à la sortie.
CREATE OR REPLACE VIEW gold_pilotage.v_dms_par_service_mois
DEFINER = CURRENT_USER SQL SECURITY DEFINER
AS SELECT
    toStartOfMonth(f.date_sortie)       AS mois,
    f.service_code,
    s.service_label,
    round(avg(f.duree_sejour_jours), 1) AS dms_jours,
    count()                             AS nb_sejours_termines,
    countIf(f.duree_sejour_jours > 30)  AS nb_longs_sejours
FROM gold_pilotage.fact_sejour f
LEFT JOIN gold_pilotage.dim_service s ON f.service_code = s.service_code
WHERE f.date_sortie IS NOT NULL
GROUP BY mois, f.service_code, s.service_label
ORDER BY mois, dms_jours DESC;

-- -----------------------------------------------------------------
-- KPI 2 : Passages aux urgences par jour
-- -----------------------------------------------------------------
-- SERVICE 'URGENCES', pas admission_mode = 'urgence' (beaucoup d'admissions
-- en urgence arrivent directement dans un autre service).
CREATE OR REPLACE VIEW gold_pilotage.v_activite_urgences
DEFINER = CURRENT_USER SQL SECURITY DEFINER
AS SELECT
    date_admission                       AS jour,
    count()                              AS nb_passages,
    countIf(discharge_mode = 'deces')    AS nb_deces,
    countIf(discharge_mode = 'mutation') AS nb_mutations_sortantes
FROM gold_pilotage.fact_sejour
WHERE service_code = 'URGENCES'
GROUP BY jour
ORDER BY jour;

-- -----------------------------------------------------------------
-- KPI 3 : Taux de réadmission à 30 jours (global)
-- -----------------------------------------------------------------
-- Tous les séjours au dénominateur, y compris en cours : le critère
-- se juge à l'admission. Pas de ventilation par service (attribuerait
-- la réadmission au service du nouveau séjour, pas à celui de la sortie).
CREATE OR REPLACE VIEW gold_pilotage.v_taux_readmission_30j
DEFINER = CURRENT_USER SQL SECURITY DEFINER
AS SELECT
    count()                           AS nb_sejours,
    sum(is_readmission_30j)           AS nb_readmissions,
    round(
        100.0 * sum(is_readmission_30j) / count(),
    1)                                AS taux_readmission_pct
FROM gold_pilotage.fact_sejour;

-- -----------------------------------------------------------------
-- KPI 4 : Alertes monitoring par jour
-- -----------------------------------------------------------------
-- Un relevé peut franchir plusieurs seuils : somme des types ≥ nb_alertes.
CREATE OR REPLACE VIEW gold_pilotage.v_alertes_monitoring_par_jour
DEFINER = CURRENT_USER SQL SECURITY DEFINER
AS SELECT
    date_mesure                     AS jour,
    count()                         AS nb_mesures_total,
    sum(is_alerte)                  AS nb_alertes,
    sum(alerte_desaturation)        AS nb_desaturations,
    sum(alerte_brady_tachycardie)   AS nb_brady_tachycardies,
    sum(alerte_fievre)              AS nb_fievres
FROM gold_pilotage.fact_monitoring
GROUP BY jour
ORDER BY jour;

-- -----------------------------------------------------------------
-- KPI 4bis : Alertes par service
-- -----------------------------------------------------------------
CREATE OR REPLACE VIEW gold_pilotage.v_alertes_par_service
DEFINER = CURRENT_USER SQL SECURITY DEFINER
AS SELECT
    m.service_code,
    s.service_label,
    count()                          AS nb_mesures,
    sum(m.is_alerte)                 AS nb_alertes,
    sum(m.alerte_desaturation)       AS nb_desaturations,
    sum(m.alerte_brady_tachycardie)  AS nb_brady_tachycardies,
    sum(m.alerte_fievre)             AS nb_fievres,
    uniqExact(m.stay_id)             AS nb_sejours_monitores
FROM gold_pilotage.fact_monitoring m
LEFT JOIN gold_pilotage.dim_service s ON m.service_code = s.service_code
GROUP BY m.service_code, s.service_label
ORDER BY nb_alertes DESC;

-- -----------------------------------------------------------------
-- KPI 5 : Mortalité (séjours terminés uniquement)
-- -----------------------------------------------------------------
-- Ventilé par service et admission_mode (case-mix urgence ≠ programmé).
CREATE OR REPLACE VIEW gold_pilotage.v_mortalite
DEFINER = CURRENT_USER SQL SECURITY DEFINER
AS SELECT
    f.service_code,
    s.service_label,
    f.admission_mode,
    count()                                     AS nb_sejours_termines,
    countIf(f.discharge_mode = 'deces')         AS nb_deces,
    round(
        100.0 * countIf(f.discharge_mode = 'deces') / count(),
    2)                                          AS taux_mortalite_pct
FROM gold_pilotage.fact_sejour f
LEFT JOIN gold_pilotage.dim_service s ON f.service_code = s.service_code
WHERE f.date_sortie IS NOT NULL
GROUP BY f.service_code, s.service_label, f.admission_mode
ORDER BY taux_mortalite_pct DESC;

-- -----------------------------------------------------------------
-- KPI 6 : Séjours en cours (grain séjour, pas d'agrégat)
-- -----------------------------------------------------------------
-- jours_depuis_admission utilise today() : volontairement non déterministe.
CREATE OR REPLACE VIEW gold_pilotage.v_sejours_en_cours
DEFINER = CURRENT_USER SQL SECURITY DEFINER
AS SELECT
    f.stay_id,
    f.patient_pseudo,
    f.service_code,
    s.service_label,
    f.date_admission,
    f.admission_mode,
    dateDiff('day', f.date_admission, today()) AS jours_depuis_admission,
    f.nb_alertes_monitoring,
    f.region_code
FROM gold_pilotage.fact_sejour f
LEFT JOIN gold_pilotage.dim_service s ON f.service_code = s.service_code
WHERE f.date_sortie IS NULL
ORDER BY jours_depuis_admission DESC;

-- -----------------------------------------------------------------
-- Fraîcheur — lit meta.pipeline_runs (possible grâce à DEFINER)
-- -----------------------------------------------------------------
-- toDateOrNull : source_date est un String ; la sentinelle 'referentiels'
-- devient NULL et max() l'ignore.
CREATE OR REPLACE VIEW gold_pilotage.v_data_freshness
DEFINER = CURRENT_USER SQL SECURITY DEFINER
AS SELECT
    max(toDateOrNull(source_date))                              AS derniere_date_source,
    dateDiff('day', max(toDateOrNull(source_date)), today())    AS anciennete_jours,
    max(finished_at)                                            AS dernier_chargement,
    countIf(status = 'success')                                 AS nb_runs_success,
    countIf(status = 'error')                                   AS nb_runs_error,
    sum(rows_processed)                                         AS nb_lignes_chargees
FROM meta.pipeline_runs
WHERE layer = 'bronze'
