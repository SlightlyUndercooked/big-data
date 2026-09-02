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
CREATE OR REPLACE VIEW gold_pilotage.fact_sejour
DEFINER = CURRENT_USER SQL SECURITY DEFINER
AS SELECT
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
CREATE OR REPLACE VIEW gold_pilotage.fact_monitoring
DEFINER = CURRENT_USER SQL SECURITY DEFINER
AS SELECT * FROM silver.fact_monitoring;

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
CREATE OR REPLACE VIEW gold_pilotage.v_activite_urgences
DEFINER = CURRENT_USER SQL SECURITY DEFINER
AS SELECT
    date_admission                       AS jour,
    count()                              AS nb_passages,
    countIf(discharge_mode = 'deces')    AS nb_deces,
    countIf(discharge_mode = 'mutation') AS nb_mutations_sortantes
FROM silver.fact_sejour
WHERE admission_mode = 'urgence'
GROUP BY jour
ORDER BY jour;

-- -----------------------------------------------------------------
-- KPI 3 : Taux de réadmission à 30 jours (global, par mois)
-- -----------------------------------------------------------------
CREATE OR REPLACE VIEW gold_pilotage.v_taux_readmission_30j
DEFINER = CURRENT_USER SQL SECURITY DEFINER
AS SELECT
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
-- KPI 3bis : Taux de réadmission à 30 jours PAR SERVICE
-- -----------------------------------------------------------------
-- Le taux global masque de fortes disparités : la réadmission précoce
-- n'a pas le même sens en cardiologie (pathologie chronique, réadmission
-- souvent attendue) qu'en chirurgie programmée (réadmission = complication).
-- Cet axe est le premier utilisé par les cadres de santé pour cibler
-- les actions d'amélioration.
--
-- On expose nb_sejours ET nb_readmissions en plus du pourcentage :
-- cela permet à Metabase de ré-agréger correctement sur plusieurs
-- services (on ne peut pas moyenner des pourcentages, il faut resommer
-- numérateur et dénominateur).
CREATE OR REPLACE VIEW gold_pilotage.v_taux_readmission_par_service
DEFINER = CURRENT_USER SQL SECURITY DEFINER
AS SELECT
    f.service_code,
    s.service_label,
    count()                     AS nb_sejours,
    sum(f.is_readmission_30j)   AS nb_readmissions,
    round(
        100.0 * sum(f.is_readmission_30j) / count(),
    1)                          AS taux_readmission_pct
FROM silver.fact_sejour f
LEFT JOIN silver.dim_service s ON f.service_code = s.service_code
WHERE f.date_sortie IS NOT NULL
GROUP BY f.service_code, s.service_label
ORDER BY taux_readmission_pct DESC;

-- -----------------------------------------------------------------
-- KPI 4 : Surveillance des constantes — alertes par jour
-- -----------------------------------------------------------------
CREATE OR REPLACE VIEW gold_pilotage.v_alertes_monitoring_par_jour
DEFINER = CURRENT_USER SQL SECURITY DEFINER
AS SELECT
    date_mesure                    AS jour,
    count()                        AS nb_mesures_total,
    sum(is_alerte)                 AS nb_alertes,
    round(100.0 * sum(is_alerte) / count(), 1) AS pct_alertes
FROM silver.fact_monitoring
GROUP BY jour
ORDER BY jour;

-- -----------------------------------------------------------------
-- KPI 4bis : Alertes monitoring PAR SERVICE, ventilées par constante
-- -----------------------------------------------------------------
-- silver.fact_monitoring ne porte pas service_code : le Parquet source
-- ne contient que stay_id. Rattacher une mesure à un service impose donc
-- une jointure vers fact_sejour. La pré-calculer ici évite que Metabase
-- rejoue ce join sur ~67 000 lignes à chaque affichage du dashboard.
--
-- INNER JOIN volontaire : les mesures rattachées à un séjour écarté en
-- Silver (incohérence temporelle) ne doivent pas être comptabilisées.
--
-- Ventilation par constante (FC / SpO2 / température) : un service dont
-- les alertes sont majoritairement des désaturations n'appelle pas la
-- même action qu'un service où c'est la température qui dérive.
-- Un même relevé peut être en alerte sur plusieurs constantes à la fois,
-- donc la somme des trois colonnes peut dépasser nb_alertes.
--
-- ATTENTION À LA LECTURE SUR LE JEU DE DONNÉES FOURNI
--   Sur les données actuelles ces trois colonnes sont dégénérées :
--   nb_alertes_fc = nb_alertes_spo2 = nb_alertes = 1369, et nb_alertes_temp = 0.
--   Vérifié : les relevés anormaux portent TOUJOURS simultanément une FC et
--   une SpO2 hors plage (valeurs sentinelles 0, 500 pour la FC ; 0, 120 pour
--   la SpO2), jamais l'une sans l'autre — 0 relevé en alerte FC seule,
--   0 en alerte SpO2 seule, 1369 sur les deux. La température, elle, reste
--   dans [36.4 ; 40.0] sur l'intégralité du fichier, donc toujours dans la
--   plage physiologique [30 ; 45].
--   Autrement dit la source ne modélise pas des dérives cliniques
--   indépendantes mais des pannes de capteur marquées par des sentinelles.
--   Il ne faut donc PAS conclure « la température n'est jamais anormale » :
--   la bonne lecture est « ce flux ne contient aucune anomalie de
--   température ». La ventilation reste en place car elle est correcte et
--   redeviendra discriminante dès que la source produira des dérives
--   indépendantes.
CREATE OR REPLACE VIEW gold_pilotage.v_alertes_par_service
DEFINER = CURRENT_USER SQL SECURITY DEFINER
AS SELECT
    f.service_code,
    s.service_label,
    count()                                        AS nb_mesures,
    sum(m.is_alerte)                               AS nb_alertes,
    round(100.0 * sum(m.is_alerte) / count(), 2)   AS pct_alertes,
    countIf(m.heart_rate NOT BETWEEN 20 AND 250)   AS nb_alertes_fc,
    countIf(m.spo2 NOT BETWEEN 50 AND 100)         AS nb_alertes_spo2,
    countIf(m.temp_c NOT BETWEEN 30.0 AND 45.0)    AS nb_alertes_temp,
    uniqExact(m.stay_id)                           AS nb_sejours_monitores
FROM silver.fact_monitoring m
INNER JOIN silver.fact_sejour f ON m.stay_id = f.stay_id
LEFT JOIN silver.dim_service s ON f.service_code = s.service_code
GROUP BY f.service_code, s.service_label
ORDER BY pct_alertes DESC;

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
    p.region_code
FROM silver.fact_sejour f
LEFT JOIN silver.dim_service s ON f.service_code = s.service_code
LEFT JOIN silver.dim_patient p ON f.patient_pseudo = p.patient_pseudo
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
