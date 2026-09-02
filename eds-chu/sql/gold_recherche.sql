-- ===================================================================
-- COUCHE GOLD — RECHERCHE CLINIQUE
-- ===================================================================
-- Schéma   : gold_recherche
-- Audience : chercheurs cliniques, épidémiologistes
-- Accès    : utilisateur ClickHouse eds_recherche (cf. sql/grants.sql)
--
-- Contraintes RGPD renforcées par rapport à gold_pilotage :
--
--   1. MINIMISATION : region_code absent (non utile à la recherche clinique,
--      et son croisement avec âge+sexe+pathologie rare augmente le risque
--      de ré-identification). service_code également retiré (cf. § ci-dessous).
--
--   2. PETITS EFFECTIFS : toute cohorte < 5 patients DISTINCTS est supprimée
--      du résultat avant restitution. Appliqué non seulement aux vues
--      agrégées (HAVING) mais AUSSI à la table de faits exposée (filtre
--      sur les codes CIM-10 atteignant le seuil). Seuil = 5 patients.
--
--   3. CLOISONNEMENT : aucun identifiant de séjour, direct ou dérivé,
--      n'est exposé (cf. § ci-dessous).
--
--   4. DEFENSE EN PROFONDEUR : le compte eds_recherche n'a aucun droit sur
--      gold_pilotage, silver ni bronze au niveau ClickHouse (sql/grants.sql).
--      Les vues s'exécutent en SQL SECURITY DEFINER — cf. gold_pilotage.sql
--      pour l'explication détaillée de ce mécanisme.
--
-- CORRECTION D'UNE FUITE DE CLOISONNEMENT (diagnostic_id)
--   La version précédente de cette vue exposait diagnostic_id en affirmant
--   en commentaire que stay_id était absent « pour éviter la jointure vers
--   les tables pilotage ». Or diagnostic_id est construit en Silver comme
--   concat(stay_id, '_', code_cim10, '_', type_diag) : le stay_id était donc
--   récupérable en clair par un simple splitByChar(diagnostic_id, '_')[1],
--   puis joignable sur gold_pilotage.fact_sejour. La protection annoncée
--   n'existait pas.
--   diagnostic_id est désormais retiré de la vue. Il n'est de toute façon
--   utile à aucune analyse de recherche : les cohortes se comptent en
--   patients distincts, jamais en lignes de diagnostic.
--
-- RETRAIT DE service_code
--   Le service d'hospitalisation est un attribut de PILOTAGE, sans valeur
--   pour l'analyse épidémiologique. Combiné à patient_pseudo, code_cim10 et
--   une date, il formait un quasi-identifiant : sur une pathologie rare,
--   « le patient du service de neurologie admis en août » peut désigner une
--   seule personne. Retiré au titre de la minimisation (RGPD art. 5.1.c).
--
-- GÉNÉRALISATION DE LA DATE
--   date_admission (jour) devient mois_admission (toStartOfMonth). La
--   précision au jour n'apporte rien à une analyse de prévalence, mais
--   réduit fortement l'espace des combinaisons identifiantes.
-- ===================================================================

CREATE DATABASE IF NOT EXISTS gold_recherche;

-- dim_patient unifiée — même définition que gold_pilotage (fusion des deux dims).
-- patient_pseudo, birth_year, sex : le dénominateur commun aux deux usages.
-- region_code absent des deux : il vit dans gold_pilotage.fact_sejour uniquement
-- (minimisation RGPD côté recherche, et cohérence de la dim partagée).
CREATE OR REPLACE VIEW gold_recherche.dim_patient
DEFINER = CURRENT_USER SQL SECURITY DEFINER
AS SELECT
    patient_pseudo,
    birth_year,
    sex
FROM silver.dim_patient;

CREATE OR REPLACE VIEW gold_recherche.dim_pathologie
DEFINER = CURRENT_USER SQL SECURITY DEFINER
AS SELECT * FROM silver.dim_pathologie;


-- -----------------------------------------------------------------
-- fact_diagnostic — projection minimisée et k-anonymisée
-- -----------------------------------------------------------------
-- Colonnes retirées par rapport à Silver, et pourquoi :
--   diagnostic_id : encapsule stay_id en clair (fuite de cloisonnement)
--   stay_id       : identifiant de séjour, axe pilotage
--   service_code  : quasi-identifiant + axe pilotage
--   date_admission: généralisée au mois
--
-- Le filtre IN (...) applique la règle des petits effectifs à la table de
-- faits elle-même, et pas seulement aux agrégats : une pathologie suivie
-- chez moins de 5 patients distincts n'apparaît dans AUCUNE ligne. Sans
-- ce filtre, un chercheur pourrait contourner les HAVING >= 5 des vues KPI
-- en réagrégeant lui-même la table de faits brute.
CREATE OR REPLACE VIEW gold_recherche.fact_diagnostic
DEFINER = CURRENT_USER SQL SECURITY DEFINER
AS SELECT
    patient_pseudo,
    code_cim10,
    type_diag,
    age_au_diagnostic,
    toStartOfMonth(date_admission) AS mois_admission
FROM silver.fact_diagnostic
WHERE code_cim10 IN (
    SELECT code_cim10
    FROM silver.fact_diagnostic
    GROUP BY code_cim10
    HAVING uniqExact(patient_pseudo) >= 5
);

-- -----------------------------------------------------------------
-- KPI 1 : Prévalence des pathologies (taille des cohortes)
-- -----------------------------------------------------------------
--
-- un même patient peut être hospitalisé plusieurs
-- fois pour la même pathologie mais un patient porteur de plusieurs
-- pathologies compte bien dans chaque cohortes concernées.
--
-- HAVING >= 5 (règle RGPD petits effectifs) : une pathologie présente
-- chez moins de 5 patients distincts n'est pas diffusée.
CREATE OR REPLACE VIEW gold_recherche.v_prevalence_pathologies
DEFINER = CURRENT_USER SQL SECURITY DEFINER
AS SELECT
    d.code_cim10,
    p.libelle,
    p.chapitre,
    count(DISTINCT d.patient_pseudo) AS nb_patients,
    count()                          AS nb_occurrences
FROM silver.fact_diagnostic d
LEFT JOIN silver.dim_pathologie p ON d.code_cim10 = p.code_cim10
GROUP BY d.code_cim10, p.libelle, p.chapitre
HAVING count(DISTINCT d.patient_pseudo) >= 5
ORDER BY nb_patients DESC;

-- -----------------------------------------------------------------
-- KPI 1bis : Prévalence dans le temps — détection de tendances
-- -----------------------------------------------------------------
-- v_prevalence_pathologies est une photo globale. Ajouter l'axe mensuel
-- permet de repérer une saisonnalité (grippe, bronchiolite) ou une
-- dynamique épidémique — l'usage épidémiologique de base de l'EDS.
--
-- Maille = mois × pathologie. Le HAVING >= 5 s'applique à CHAQUE cellule
-- mensuelle, pas au total : une pathologie fréquente sur l'ensemble de la
-- période mais rare un mois donné verra ce mois-là supprimé du résultat.
-- C'est volontaire (protection des petits effectifs), mais cela signifie
-- que la somme des nb_patients mensuels est inférieure au nb_patients
-- global de v_prevalence_pathologies — les deux vues ne se recoupent pas
-- exactement, et c'est attendu.
-- Même convention que v_prevalence_pathologies : tous types de diagnostics.
CREATE OR REPLACE VIEW gold_recherche.v_prevalence_mensuelle
DEFINER = CURRENT_USER SQL SECURITY DEFINER
AS SELECT
    toStartOfMonth(d.date_admission) AS mois,
    d.code_cim10,
    p.libelle,
    p.chapitre,
    count(DISTINCT d.patient_pseudo) AS nb_patients,
    count()                          AS nb_occurrences
FROM silver.fact_diagnostic d
LEFT JOIN silver.dim_pathologie p ON d.code_cim10 = p.code_cim10
GROUP BY mois, d.code_cim10, p.libelle, p.chapitre
HAVING count(DISTINCT d.patient_pseudo) >= 5
ORDER BY mois, nb_patients DESC;

-- -----------------------------------------------------------------
-- KPI 2 : Description de cohorte — distribution âge et sexe
-- -----------------------------------------------------------------
-- L'âge au diagnostic est calculé en Silver (fact_diagnostic.age_au_diagnostic
-- = toYear(admission) - birth_year) : ici on ne fait que le découpage en tranches.
--
-- Agrégé par TRANCHE DE 10 ANS pour réduire le risque de ré-identification :
--   (age DIV 10) * 10     → borne inférieure de la tranche (ex: 60)
--   (age DIV 10) * 10 + 9 → borne supérieure (ex: 69)
--
-- HAVING >= 5 sur chaque cellule (code × sexe × tranche_age).
-- Une cellule avec moins de 5 patients est supprimée du résultat.
--
-- Même convention que v_prevalence_pathologies (tous types de diagnostics) :
-- la description démographique porte sur les MÊMES cohortes que la
-- prévalence, sinon les deux vues ne se recouperaient pas.
CREATE OR REPLACE VIEW gold_recherche.v_description_cohorte
DEFINER = CURRENT_USER SQL SECURITY DEFINER
AS SELECT
    d.code_cim10,
    path.libelle                              AS pathologie,
    p.sex,
    d.age_au_diagnostic DIV 10 * 10           AS tranche_age_debut,
    d.age_au_diagnostic DIV 10 * 10 + 9       AS tranche_age_fin,
    count(DISTINCT d.patient_pseudo)          AS nb_patients
FROM silver.fact_diagnostic d
LEFT JOIN silver.dim_patient    p    ON d.patient_pseudo = p.patient_pseudo
LEFT JOIN silver.dim_pathologie path ON d.code_cim10 = path.code_cim10
GROUP BY
    d.code_cim10,
    path.libelle,
    p.sex,
    tranche_age_debut,
    tranche_age_fin
HAVING count(DISTINCT d.patient_pseudo) >= 5
ORDER BY d.code_cim10, tranche_age_debut;

-- -----------------------------------------------------------------
-- KPI 3 : Comorbidités — pathologies fréquemment associées
-- -----------------------------------------------------------------
-- type_diag = 'associe' était chargé jusqu'en Silver mais exploité par
-- aucune vue : les deux KPI précédents filtrent tous deux sur 'principal'.
-- Toute l'information de comorbidité était donc inaccessible aux
-- chercheurs, alors que c'est un usage central de la recherche clinique
-- (« quelles pathologies accompagnent l'hypertension ? »).
--
-- Auto-jointure sur stay_id : on apparie, au sein d'un même séjour, le
-- diagnostic principal avec chacun de ses diagnostics associés. Le grain
-- du résultat est donc la PAIRE (principal, associé).
--
-- stay_id sert ici de clé de jointure interne mais n'apparaît pas dans le
-- résultat : la vue ne restitue que des agrégats de paires de codes.
--
-- HAVING >= 5 : une association de pathologies observée chez moins de
-- 5 patients distincts n'est pas diffusée. C'est particulièrement
-- important ici, car une combinaison rare de deux pathologies est
-- bien plus identifiante qu'une pathologie isolée.
CREATE OR REPLACE VIEW gold_recherche.v_comorbidites
DEFINER = CURRENT_USER SQL SECURITY DEFINER
AS SELECT
    princ.code_cim10                     AS code_principal,
    lib_princ.libelle                    AS libelle_principal,
    asso.code_cim10                      AS code_associe,
    lib_asso.libelle                     AS libelle_associe,
    lib_asso.chapitre                    AS chapitre_associe,
    count(DISTINCT princ.patient_pseudo) AS nb_patients
FROM silver.fact_diagnostic princ
INNER JOIN silver.fact_diagnostic asso
    ON princ.stay_id = asso.stay_id
LEFT JOIN silver.dim_pathologie lib_princ ON princ.code_cim10 = lib_princ.code_cim10
LEFT JOIN silver.dim_pathologie lib_asso  ON asso.code_cim10  = lib_asso.code_cim10
WHERE princ.type_diag = 'principal'
  AND asso.type_diag  = 'associe'
GROUP BY
    princ.code_cim10,
    lib_princ.libelle,
    asso.code_cim10,
    lib_asso.libelle,
    lib_asso.chapitre
HAVING count(DISTINCT princ.patient_pseudo) >= 5
ORDER BY nb_patients DESC
