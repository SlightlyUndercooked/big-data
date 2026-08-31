-- ===================================================================
-- COUCHE GOLD — RECHERCHE CLINIQUE
-- ===================================================================
-- Schéma   : gold_recherche
-- Audience : chercheurs cliniques, épidémiologistes
-- Accès    : groupe Metabase "chercheurs" uniquement
--
-- Contraintes RGPD renforcées par rapport à gold_pilotage :
--
--   1. MINIMISATION : region_code absent (non utile à la recherche clinique,
--      et son croisement avec âge+sexe+pathologie rare augmente le risque
--      de ré-identification).
--
--   2. PETITS EFFECTIFS : toute cohorte < 5 patients DISTINCTS est supprimée
--      du résultat avant restitution. Implémentation : HAVING sur toutes
--      les vues agrégées. Seuil = 5 patients (standard de recherche en santé).
--
--   3. CLOISONNEMENT : stay_id absent de fact_diagnostic pour empêcher
--      une jointure vers gold_pilotage via un stay_id commun.
--      Un chercheur ne doit pas pouvoir retrouver les données de pilotage.
--
--   4. DONNÉES AGRÉGÉES UNIQUEMENT dans les vues KPI : le chercheur accède
--      à des distributions, pas à des données individuelles pour les analyses.
-- ===================================================================

CREATE DATABASE IF NOT EXISTS gold_recherche;

-- dim_patient unifiée — même définition que gold_pilotage (fusion des deux dims).
-- patient_pseudo, birth_year, sex : le dénominateur commun aux deux usages.
-- region_code absent des deux : il vit dans gold_pilotage.fact_sejour uniquement
-- (minimisation RGPD côté recherche, et cohérence de la dim partagée).
CREATE OR REPLACE VIEW gold_recherche.dim_patient AS
SELECT
    patient_pseudo,
    birth_year,
    sex
FROM silver.dim_patient;

CREATE OR REPLACE VIEW gold_recherche.dim_pathologie AS
SELECT * FROM silver.dim_pathologie;


-- fact_diagnostic : projection sans stay_id (cloisonnement)
-- et sans les colonnes de séjour (mode admission/sortie = données de pilotage).
CREATE OR REPLACE VIEW gold_recherche.fact_diagnostic AS
SELECT
    diagnostic_id,
    patient_pseudo,
    code_cim10,
    date_admission,
    type_diag,
    service_code
    -- stay_id absent : évite la jointure vers les tables pilotage
FROM silver.fact_diagnostic;

-- -----------------------------------------------------------------
-- KPI 1 : Prévalence des pathologies (taille des cohortes)
-- -----------------------------------------------------------------
-- Filtre type_diag = 'principal' : mesure la prévalence réelle.
-- Un diagnostic 'associe' représente une comorbidité, pas la raison
-- principale de l'hospitalisation — l'inclure biaise la prévalence.
--
-- count(DISTINCT patient_pseudo) : compte les patients uniques,
-- pas les occurrences (un même patient peut être hospitalisé plusieurs fois
-- pour la même pathologie).
--
-- HAVING >= 5 (règle RGPD petits effectifs) : une pathologie présente
-- chez moins de 5 patients distincts n'est pas diffusée.
CREATE OR REPLACE VIEW gold_recherche.v_prevalence_pathologies AS
SELECT
    d.code_cim10,
    p.libelle,
    p.chapitre,
    count(DISTINCT d.patient_pseudo) AS nb_patients,
    count()                          AS nb_occurrences
FROM silver.fact_diagnostic d
LEFT JOIN silver.dim_pathologie p ON d.code_cim10 = p.code_cim10
WHERE d.type_diag = 'principal'
GROUP BY d.code_cim10, p.libelle, p.chapitre
HAVING count(DISTINCT d.patient_pseudo) >= 5
ORDER BY nb_patients DESC;

-- -----------------------------------------------------------------
-- KPI 2 : Description de cohorte — distribution âge et sexe
-- -----------------------------------------------------------------
-- Calcul de l'âge à l'admission :
--   toYear(date_admission) - birth_year
--   (approximation correcte pour des statistiques de population)
--
-- Agrégé par TRANCHE DE 10 ANS pour réduire le risque de ré-identification :
--   (age DIV 10) * 10     → borne inférieure de la tranche (ex: 60)
--   (age DIV 10) * 10 + 9 → borne supérieure (ex: 69)
--
-- HAVING >= 5 sur chaque cellule (code × sexe × tranche_age).
-- Une cellule avec moins de 5 patients est supprimée du résultat.
CREATE OR REPLACE VIEW gold_recherche.v_description_cohorte AS
SELECT
    d.code_cim10,
    path.libelle                                              AS pathologie,
    p.sex,
    (toYear(d.date_admission) - p.birth_year) DIV 10 * 10    AS tranche_age_debut,
    (toYear(d.date_admission) - p.birth_year) DIV 10 * 10 + 9 AS tranche_age_fin,
    count(DISTINCT d.patient_pseudo)                          AS nb_patients
FROM silver.fact_diagnostic d
LEFT JOIN silver.dim_patient    p    ON d.patient_pseudo = p.patient_pseudo
LEFT JOIN silver.dim_pathologie path ON d.code_cim10 = path.code_cim10
WHERE d.type_diag = 'principal'
GROUP BY
    d.code_cim10,
    path.libelle,
    p.sex,
    tranche_age_debut,
    tranche_age_fin
HAVING count(DISTINCT d.patient_pseudo) >= 5
ORDER BY d.code_cim10, tranche_age_debut
