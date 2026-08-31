-- ===================================================================
-- COUCHE GOLD — PILOTAGE HOSPITALIER
-- ===================================================================
-- Schéma   : gold_pilotage
-- Audience : opérationnels (direction, cadres de santé, administratifs)
-- Accès    : groupe Metabase "operationnels" uniquement
--
-- dim_patient est IDENTIQUE à gold_recherche (fusion des deux dims) :
--   patient_pseudo, birth_year, sex
--   → region_code n'est PAS dans la dim patient ; il est dénormalisé
--     dans fact_sejour via un LEFT JOIN. Raison : region_code est un
--     attribut du séjour (adresse au moment de l'admission, potentiellement
--     changeante) plus qu'un attribut stable du patient. Ce choix permet
--     aussi de partager une dim_patient commune avec gold_recherche.
-- ===================================================================

CREATE DATABASE IF NOT EXISTS gold_pilotage;

-- dim_patient unifiée — même définition que gold_recherche
-- birth_year et sex suffisent pour les analyses démographiques du pilotage.
-- region_code est disponible dans fact_sejour (cf. ci-dessous).
CREATE OR REPLACE VIEW gold_pilotage.dim_patient AS
SELECT
    patient_pseudo,
    birth_year,
    sex
FROM silver.dim_patient;

CREATE OR REPLACE VIEW gold_pilotage.dim_service AS
SELECT * FROM silver.dim_service;


-- fact_sejour enrichie de region_code (dénormalisé depuis dim_patient Silver).
-- region_code reste disponible pour le pilotage (analyse des flux géographiques,
-- zone de chalandise) sans être dans la dim_patient partagée.
CREATE OR REPLACE VIEW gold_pilotage.fact_sejour AS
SELECT
    f.stay_id,
    f.patient_pseudo,
    f.service_code,
    f.date_admission,
    f.date_sortie,
    f.admission_mode,
    f.discharge_mode,
    f.duree_sejour_jours,
    f.is_readmission_30j,
    f.nb_alertes_monitoring,
    p.region_code
FROM silver.fact_sejour f
LEFT JOIN silver.dim_patient p USING (patient_pseudo);

-- fact_monitoring : relevés bruts avec flag alerte, sans jointure de dimensions.
-- Permet à Metabase de construire n'importe quelle agrégation temporelle
-- (par jour, par heure, par séjour) directement sur la fact.
CREATE OR REPLACE VIEW gold_pilotage.fact_monitoring AS
SELECT * FROM silver.fact_monitoring;

-- -----------------------------------------------------------------
-- KPI 1 : Durée Moyenne de Séjour (DMS) par service
-- -----------------------------------------------------------------
CREATE OR REPLACE VIEW gold_pilotage.v_dms_par_service AS
SELECT
    f.service_code,
    s.service_label,
    round(avg(f.duree_sejour_jours), 1) AS dms_jours,
    count()                             AS nb_sejours_termines,
    countIf(f.duree_sejour_jours > 30)  AS nb_longs_sejours
FROM silver.fact_sejour f
LEFT JOIN silver.dim_service s ON f.service_code = s.service_code
WHERE f.date_sortie IS NOT NULL
GROUP BY f.service_code, s.service_label
ORDER BY dms_jours DESC;

-- -----------------------------------------------------------------
-- KPI 2 : Activité des urgences — passages par jour
-- -----------------------------------------------------------------
CREATE OR REPLACE VIEW gold_pilotage.v_activite_urgences AS
SELECT
    date_admission                       AS jour,
    count()                              AS nb_passages,
    countIf(discharge_mode = 'deces')    AS nb_deces,
    countIf(discharge_mode = 'mutation') AS nb_mutations_sortantes
FROM silver.fact_sejour
WHERE admission_mode = 'urgence'
GROUP BY jour
ORDER BY jour;

-- -----------------------------------------------------------------
-- KPI 3 : Taux de réadmission à 30 jours
-- -----------------------------------------------------------------
CREATE OR REPLACE VIEW gold_pilotage.v_taux_readmission_30j AS
SELECT
    toStartOfMonth(date_admission)    AS mois,
    count()                           AS nb_sejours,
    sum(is_readmission_30j)           AS nb_readmissions,
    round(
        100.0 * sum(is_readmission_30j) / count(),
    1)                                AS taux_readmission_pct
FROM silver.fact_sejour
WHERE date_sortie IS NOT NULL
GROUP BY mois
ORDER BY mois;

-- -----------------------------------------------------------------
-- KPI 4 : Surveillance des constantes — alertes par jour
-- -----------------------------------------------------------------
-- Construit sur silver.fact_monitoring (la fact propre) plutôt que
-- sur bronze.monitoring directement.
CREATE OR REPLACE VIEW gold_pilotage.v_alertes_monitoring_par_jour AS
SELECT
    date_mesure                    AS jour,
    count()                        AS nb_mesures_total,
    sum(is_alerte)                 AS nb_alertes,
    round(100.0 * sum(is_alerte) / count(), 1) AS pct_alertes
FROM silver.fact_monitoring
GROUP BY jour
ORDER BY jour
