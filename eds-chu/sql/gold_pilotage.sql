-- ===================================================================
-- COUCHE GOLD — PILOTAGE HOSPITALIER
-- ===================================================================
-- Schéma   : gold_pilotage
-- Audience : opérationnels (direction, cadres de santé, administratifs)
-- Accès    : groupe Metabase "operationnels" uniquement
--
-- Implémentation : des VIEWS sur les tables Silver.
-- Avantage vs tables : aucune duplication, toujours à jour dès que
-- Silver est reconstruit. Les vues sont légères à re-créer.
--
-- Contenu exposé :
--   - Données de fonctionnement hospitalier (séjours, services, temps)
--   - Constantes agrégées (alertes par jour, pas le détail individuel)
--   - region_code inclus (analyse des flux géographiques — utile au pilotage)
--
-- NON exposé (cloisonnement) :
--   - Diagnostics CIM-10 (données cliniques → réservées à la recherche)
--   - Détail du monitoring par relevé (trop granulaire, agrégé dans fact_sejour)
-- ===================================================================

CREATE DATABASE IF NOT EXISTS gold_pilotage;

-- Projection de dim_patient pour le pilotage
-- region_code présent : utile pour analyser la zone de chalandise du CHU.
-- Pas d'age_admission : l'âge précis n'est pas nécessaire au pilotage opérationnel.
CREATE OR REPLACE VIEW gold_pilotage.dim_patient AS
SELECT
    patient_pseudo,
    birth_year,
    sex,
    region_code
FROM silver.dim_patient;

CREATE OR REPLACE VIEW gold_pilotage.dim_service AS
SELECT * FROM silver.dim_service;

CREATE OR REPLACE VIEW gold_pilotage.dim_temps AS
SELECT * FROM silver.dim_temps;

-- Vue principale : tous les faits séjours avec indicateurs calculés
CREATE OR REPLACE VIEW gold_pilotage.fact_sejour AS
SELECT * FROM silver.fact_sejour;

-- -----------------------------------------------------------------
-- KPI 1 : Durée Moyenne de Séjour (DMS) par service
-- -----------------------------------------------------------------
-- Indicateur clé de performance hospitalière. Permet de :
--   - Comparer les services entre eux
--   - Détecter les services avec une DMS anormalement haute
--   - Suivre l'évolution dans le temps
--
-- ON EXCLUT les séjours en cours (date_sortie IS NULL) car leur durée
-- est inconnue et biaise la moyenne vers le bas (durée partielle).
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
-- Filtre admission_mode = 'urgence' pour isoler les passages aux urgences.
-- Les mutations depuis un autre service ne sont pas comptées comme
-- des passages urgences (c'est une admission planifiée différée).
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
-- Indicateur de qualité des soins : une réadmission précoce peut signaler
-- une sortie prématurée ou un suivi ambulatoire insuffisant.
-- La base est constituée des séjours TERMINÉS (date_sortie NOT NULL).
-- Les séjours en cours ne peuvent pas encore être "réadmis" post-sortie.
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
-- Vue directe sur bronze.monitoring pour garder la granularité temporelle.
-- On peut voir l'évolution des alertes heure par heure si nécessaire
-- (Metabase peut grouper par heure ou par jour).
--
-- Plages physiologiques (sujet §3) :
--   FC : 20–250 bpm | SpO2 : 50–100 % | Temp : 30–45 °C
CREATE OR REPLACE VIEW gold_pilotage.v_alertes_monitoring_par_jour AS
SELECT
    toDate(ts)  AS jour,
    count()     AS nb_mesures_total,
    countIf(
        heart_rate NOT BETWEEN 20 AND 250
        OR spo2    NOT BETWEEN 50 AND 100
        OR temp_c  NOT BETWEEN 30.0 AND 45.0
    )           AS nb_alertes,
    round(
        100.0 * countIf(
            heart_rate NOT BETWEEN 20 AND 250
            OR spo2    NOT BETWEEN 50 AND 100
            OR temp_c  NOT BETWEEN 30.0 AND 45.0
        ) / count(),
    1)          AS pct_alertes
FROM bronze.monitoring
GROUP BY jour
ORDER BY jour
