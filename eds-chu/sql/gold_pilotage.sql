-- ===================================================================
-- COUCHE GOLD — PILOTAGE HOSPITALIER
-- ===================================================================
-- Schéma   : gold_pilotage
-- Audience : opérationnels (direction, cadres de santé, administratifs)
-- Accès    : utilisateur ClickHouse eds_pilotage (cf. sql/grants.sql)
--
-- dim_patient est IDENTIQUE à gold_recherche (fusion des deux dims) :
--   patient_pseudo, birth_year, sex
--   → region_code n'est PAS dans la dim patient ; il est dénormalisé
--     dans fact_sejour via un LEFT JOIN. Raison : region_code est un
--     attribut du séjour (adresse au moment de l'admission, potentiellement
--     changeante) plus qu'un attribut stable du patient. Ce choix permet
--     aussi de partager une dim_patient commune avec gold_recherche.
--
-- POURQUOI "DEFINER = CURRENT_USER SQL SECURITY DEFINER" SUR TOUTES LES VUES
--   Par défaut, une vue ClickHouse s'exécute avec les droits de l'APPELANT
--   (SQL SECURITY INVOKER). Or les comptes eds_pilotage / eds_recherche
--   n'ont volontairement aucun droit sur silver.* ni bronze.* : ils ne
--   voient QUE leur base Gold. Sans SQL SECURITY DEFINER, chaque requête
--   Metabase échouerait avec "Not enough privileges" au moment où la vue
--   tente de lire silver.
--   Avec DEFINER, la vue s'exécute avec les droits de son créateur (le
--   compte admin du pipeline). La vue devient donc la frontière de sécurité :
--   l'utilisateur accède aux données AU TRAVERS de la projection qu'on a
--   définie, jamais aux tables sous-jacentes. C'est exactement le
--   cloisonnement demandé — les colonnes exclues d'une vue sont réellement
--   inatteignables, pas seulement masquées dans l'interface.
-- ===================================================================

CREATE DATABASE IF NOT EXISTS gold_pilotage;

-- dim_patient unifiée — même définition que gold_recherche
-- birth_year et sex suffisent pour les analyses démographiques du pilotage.
-- region_code est disponible dans fact_sejour (cf. ci-dessous).
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


-- fact_sejour enrichie de region_code (dénormalisé depuis dim_patient Silver).
-- region_code reste disponible pour le pilotage (analyse des flux géographiques,
-- zone de chalandise) sans être dans la dim_patient partagée.
--
-- is_readmission_30j réadmission précoce :
--   le patient est réadmis entre 1 et 30 jours après la sortie de son
--   séjour précédent. Calculé par fenêtre lagInFrame (O(n), pas de
--   self-join O(n²)). La borne à 1 exclut le même jour (mutation entre
--   services, pas une réadmission).
--
-- nb_alertes_monitoring — nombre de relevés du séjour franchissant au
--   moins un SEUIL CLINIQUE (cf. gold_pilotage.fact_monitoring ci-dessous).
CREATE OR REPLACE VIEW gold_pilotage.fact_sejour
DEFINER = CURRENT_USER SQL SECURITY DEFINER
AS
WITH alertes_par_sejour AS (
    SELECT
        stay_id,
        countIf(
            spo2 < 92
            OR heart_rate < 50 OR heart_rate >100
            OR temp_c > 38.5
        ) AS nb_alertes_monitoring
    FROM silver.fact_monitoring
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

-- fact_monitoring
--
-- Silver garantit des valeurs physiologiquement plausibles (les aberrations
-- capteur sont écartées) . ici on qualifie cliniquement chaque relevé :
--   SpO2 < 92 % → désaturation en oxygène
--   FC < 50 ou > 100 bpm → bradycardie / tachycardie
--   Température > 38,5 °C → fièvre
-- is_alerte = au moins un des trois seuils franchi.
CREATE OR REPLACE VIEW gold_pilotage.fact_monitoring
DEFINER = CURRENT_USER SQL SECURITY DEFINER
AS SELECT
    stay_id,
    ts,
    date_mesure,
    heart_rate,
    spo2,
    temp_c,
    toUInt8(spo2 < 92) AS alerte_desaturation,
    toUInt8(heart_rate < 50 OR heart_rate > 100) AS alerte_brady_tachycardie,
    toUInt8(temp_c > 38.5) AS alerte_fievre,
    toUInt8(
        spo2 < 92
        OR heart_rate < 50 OR heart_rate > 100
        OR temp_c > 38.5
    ) AS is_alerte
FROM silver.fact_monitoring;

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
FROM silver.fact_sejour f
LEFT JOIN silver.dim_service s ON f.service_code = s.service_code
WHERE f.date_sortie IS NOT NULL
GROUP BY f.service_code, s.service_label
ORDER BY dms_jours DESC;

-- -----------------------------------------------------------------
-- KPI 1bis : DMS par service ET par mois — suivi de tendance
-- -----------------------------------------------------------------
-- v_dms_par_service est une photo globale : elle ne dit pas si la DMS
-- d'un service se dégrade. Cette vue ajoute l'axe temporel.
--
-- Rattachement au mois de SORTIE (et non d'admission) : un séjour ne
-- contribue à la DMS qu'une fois terminé, sa durée n'est connue qu'à
-- la sortie. C'est la convention retenue en pilotage hospitalier.
-- Les séjours en cours sont exclus (durée inconnue) — cf. v_sejours_en_cours.
CREATE OR REPLACE VIEW gold_pilotage.v_dms_par_service_mois
DEFINER = CURRENT_USER SQL SECURITY DEFINER
AS SELECT
    toStartOfMonth(f.date_sortie)       AS mois,
    f.service_code,
    s.service_label,
    round(avg(f.duree_sejour_jours), 1) AS dms_jours,
    count()                             AS nb_sejours_termines,
    countIf(f.duree_sejour_jours > 30)  AS nb_longs_sejours
FROM silver.fact_sejour f
LEFT JOIN silver.dim_service s ON f.service_code = s.service_code
WHERE f.date_sortie IS NOT NULL
GROUP BY mois, f.service_code, s.service_label
ORDER BY mois, dms_jours DESC;

-- -----------------------------------------------------------------
-- KPI 2 : Activité urgences — passages par jour
-- -----------------------------------------------------------------
-- Un « passage aux urgences » = un séjour dans le SERVICE des urgences
-- (service_code = 'URGENCES'), pas une admission en mode urgence :
-- 2 590 séjours sont admis en mode 'urgence' directement dans d'autres
-- services (cardio, neuro...) sans passer par les urgences — ils relèvent
-- de l'activité de ces services, pas de celle des urgences.
CREATE OR REPLACE VIEW gold_pilotage.v_activite_urgences
DEFINER = CURRENT_USER SQL SECURITY DEFINER
AS SELECT
    date_admission                       AS jour,
    count()                              AS nb_passages,
    countIf(discharge_mode = 'deces')    AS nb_deces,
    countIf(discharge_mode = 'mutation') AS nb_mutations_sortantes
FROM silver.fact_sejour
WHERE service_code = 'URGENCES'
GROUP BY jour
ORDER BY jour;

-- -----------------------------------------------------------------
-- KPI 3 : Taux de réadmission à 30 jours (GLOBAL)
-- -----------------------------------------------------------------
-- Indicateur global de qualité des soins : une seule ligne.
-- La règle métier (fenêtre 1-30 jours) est définie dans
-- gold_pilotage.fact_sejour ; cette vue ne fait que l'agréger.
--
-- TOUS les séjours comptent au dénominateur, y compris les séjours en
-- cours : la réadmission se juge à l'ADMISSION (le patient est revenu
-- moins de 30 jours après sa sortie précédente), peu importe que le
-- nouveau séjour soit terminé. Filtrer sur date_sortie IS NOT NULL
-- écarterait à tort les réadmissions actuellement hospitalisées.
CREATE OR REPLACE VIEW gold_pilotage.v_taux_readmission_30j
DEFINER = CURRENT_USER SQL SECURITY DEFINER
AS SELECT
    count()                           AS nb_sejours,
    sum(is_readmission_30j)           AS nb_readmissions,
    round(
        100.0 * sum(is_readmission_30j) / count(),
    1)                                AS taux_readmission_pct
FROM gold_pilotage.fact_sejour;

-- NOTE : une version « par service » (v_taux_readmission_par_service) a
-- existé puis a été retirée. La réadmission est un indicateur de qualité
-- GLOBAL : la ventiler par service attribuait la réadmission au service
-- du NOUVEAU séjour, alors que la qualité questionnée est celle du service
-- qui a laissé sortir le patient (souvent différent). Plutôt que de
-- diffuser un indicateur à l'attribution trompeuse, on s'en tient au
-- taux global demandé par le besoin métier.

-- -----------------------------------------------------------------
-- KPI 4 : Surveillance des constantes — relevés en alerte par jour
-- -----------------------------------------------------------------
-- Seuils cliniques définis dans gold_pilotage.fact_monitoring :
--   SpO2 < 92 % | FC < 50 ou > 100 bpm | Temp > 38,5 °C
-- Ventilation par type d'alerte : un même relevé peut franchir
-- plusieurs seuils, la somme des trois colonnes peut dépasser nb_alertes.
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
-- KPI 4bis : Alertes monitoring PAR SERVICE, ventilées par type
-- -----------------------------------------------------------------
-- silver.fact_monitoring ne porte pas service_code : le Parquet source
-- ne contient que stay_id. Rattacher une mesure à un service impose donc
-- une jointure vers fact_sejour. La pré-calculer ici évite que Metabase
-- rejoue ce join sur ~41 000 lignes à chaque affichage du dashboard.
--
-- INNER JOIN volontaire : les mesures rattachées à un séjour écarté en
-- Silver (incohérence temporelle) ne doivent pas être comptabilisées.
--
-- Ventilation par type d'alerte clinique : un service dont les alertes
-- sont majoritairement des désaturations n'appelle pas la même action
-- qu'un service où domine la fièvre. Un même relevé peut franchir
-- plusieurs seuils, la somme des trois colonnes peut dépasser nb_alertes.
CREATE OR REPLACE VIEW gold_pilotage.v_alertes_par_service
DEFINER = CURRENT_USER SQL SECURITY DEFINER
AS SELECT
    f.service_code,
    s.service_label,
    count()                          AS nb_mesures,
    sum(m.is_alerte)                 AS nb_alertes,
    sum(m.alerte_desaturation)       AS nb_desaturations,
    sum(m.alerte_brady_tachycardie)  AS nb_brady_tachycardies,
    sum(m.alerte_fievre)             AS nb_fievres,
    uniqExact(m.stay_id)             AS nb_sejours_monitores
FROM gold_pilotage.fact_monitoring m
INNER JOIN silver.fact_sejour f ON m.stay_id = f.stay_id
LEFT JOIN silver.dim_service s ON f.service_code = s.service_code
GROUP BY f.service_code, s.service_label
ORDER BY nb_alertes DESC;

-- -----------------------------------------------------------------
-- KPI 5 : Mortalité hospitalière, toutes admissions confondues
-- -----------------------------------------------------------------
-- Jusqu'ici nb_deces n'existait que dans v_activite_urgences, donc
-- restreint aux admissions en urgence : les décès survenus lors de
-- séjours programmés ou de mutations étaient invisibles du pilotage.
-- Cette vue couvre l'ensemble des séjours terminés.
--
-- Restriction aux séjours terminés (date_sortie NOT NULL) : un séjour
-- en cours n'a pas encore de discharge_mode, l'inclure au dénominateur
-- diluerait artificiellement le taux.
--
-- Ventilation par admission_mode en plus du service : la mortalité en
-- urgence et en programmé ne se comparent pas (case-mix différent).
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
FROM silver.fact_sejour f
LEFT JOIN silver.dim_service s ON f.service_code = s.service_code
WHERE f.date_sortie IS NOT NULL
GROUP BY f.service_code, s.service_label, f.admission_mode
ORDER BY taux_mortalite_pct DESC;

-- -----------------------------------------------------------------
-- KPI 6 : Séjours en cours — patients actuellement hospitalisés
-- -----------------------------------------------------------------
-- discharge_ts NULL est une valeur LÉGITIME (sujet §3) : le patient est
-- encore hospitalisé. Ces séjours sont conservés en Silver mais aucune
-- vue Gold ne les isolait — or c'est la vue la plus opérationnelle du
-- pilotage (qui est là, depuis combien de temps, dans quel service).
--
-- jours_depuis_admission utilise today() : la vue est donc volontairement
-- non déterministe, sa valeur change chaque jour. C'est le comportement
-- attendu pour un suivi temps réel — mais cela signifie qu'une capture
-- d'écran de ce tableau n'est pas reproductible à l'identique plus tard.
--
-- Cette vue reste au grain séjour (pas d'agrégat) : elle sert à lister
-- des cas individuels pour l'action opérationnelle, pas à faire des stats.
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
LEFT JOIN silver.dim_service s ON f.service_code = s.service_code
WHERE f.date_sortie IS NULL
ORDER BY jours_depuis_admission DESC;

-- -----------------------------------------------------------------
-- Fraîcheur des données — traçabilité exposée au dashboard
-- -----------------------------------------------------------------
-- Sans cette vue, un opérationnel qui consulte un dashboard n'a aucun
-- moyen de savoir si les chiffres datent d'aujourd'hui ou de la semaine
-- dernière (pipeline planté, cron arrêté...). Elle matérialise la
-- contrainte de traçabilité du sujet (§5) directement dans l'interface.
--
-- Source : meta.pipeline_runs, la table d'audit alimentée par step1.
-- C'est le seul endroit de Gold qui lit meta — possible uniquement
-- grâce à SQL SECURITY DEFINER (eds_pilotage n'a aucun droit sur meta).
--
-- toDateOrNull sur source_date : la colonne est un String qui vaut soit
-- 'YYYY-MM-DD', soit la sentinelle 'referentiels'. toDateOrNull renvoie
-- NULL sur cette dernière, et max() ignore les NULL — la sentinelle est
-- donc écartée sans filtre explicite.
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
