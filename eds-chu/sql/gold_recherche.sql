-- ===================================================================
-- COUCHE GOLD — RECHERCHE CLINIQUE
-- ===================================================================
-- Compte ClickHouse eds_recherche (step4). DEFINER : voir gold_pilotage.sql.
--
-- Minimisation : pas de region_code, service_code, stay_id, diagnostic_id
-- (ce dernier encapsule stay_id en concat). Date ramenée au mois.
--
-- Petits effectifs : k ≥ 5 patients distincts, à la fois sur les vues
-- agrégées (HAVING) et sur fact_diagnostic (sinon un chercheur
-- réagrège la table brute et contourne le HAVING).
-- ===================================================================

CREATE DATABASE IF NOT EXISTS gold_recherche;

-- Même dim_patient que gold_pilotage. region_code : fact_sejour pilotage.
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
-- fact_diagnostic — projection minimisée + k-anonymat sur les codes
-- -----------------------------------------------------------------
-- Retirés : diagnostic_id (contient stay_id), stay_id, service_code,
-- date au jour (→ mois).
-- Filtre IN (...) : un code suivi chez < 5 patients n'apparaît nulle part.
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
-- KPI 1 : Prévalence (tous types de diagnostics)
-- -----------------------------------------------------------------
-- Un patient hospitalisé plusieurs fois pour le même code compte 1 fois
-- (DISTINCT). Un patient avec plusieurs codes compte dans chaque cohorte.
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
-- KPI 1bis : Prévalence mensuelle
-- -----------------------------------------------------------------
-- HAVING ≥ 5 par cellule (mois × code), pas sur le total : la somme
-- mensuelle peut être inférieure à v_prevalence_pathologies.
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
-- KPI 2 : Description de cohorte (tranches de 10 ans)
-- -----------------------------------------------------------------
-- Âge déjà calculé en Silver. HAVING ≥ 5 par cellule (code × sexe × tranche).
-- Tous types de diagnostics, comme la prévalence.
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
-- KPI 3 : Comorbidités (principal × associé, même stay_id)
-- -----------------------------------------------------------------
-- stay_id sert de clé interne, absent du résultat.
-- HAVING ≥ 5 : une paire rare est plus identifiante qu'un code isolé.
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
