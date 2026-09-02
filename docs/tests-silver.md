
  1. Les séjours incohérents ont bien été écartés

  -- Bronze doit avoir 68, Silver doit avoir 0
  SELECT count() FROM bronze.sejours
  WHERE discharge_ts IS NOT NULL AND discharge_ts < admission_ts;

  SELECT count() FROM silver.sejours_stg
  WHERE discharge_ts IS NOT NULL AND discharge_ts < admission_ts;

  2. La déduplication patients a bien fonctionné

  -- Bronze contient plusieurs versions par patient (dump cumulatif quotidien),
  -- Silver doit être strictement inférieur
  SELECT count() FROM bronze.patients;
  SELECT count() FROM silver.dim_patient;   -- 6000

  -- Vérifier qu'il n'y a plus de doublons
  SELECT patient_pseudo, count() AS nb
  FROM silver.dim_patient
  GROUP BY patient_pseudo
  HAVING nb > 1;
  -- doit retourner 0 lignes

  3. Les diagnostics orphelins ont bien été écartés

  -- Silver doit être <= Bronze
  SELECT count() FROM bronze.diagnostics;
  SELECT count() FROM silver.fact_diagnostic;   -- 12720

  -- Aucun diagnostic ne doit pointer vers un séjour absent de sejours_stg
  SELECT count() FROM silver.fact_diagnostic f
  WHERE f.stay_id NOT IN (SELECT stay_id FROM silver.sejours_stg);
  -- doit retourner 0

  4. Les relevés monitoring aberrants ont bien été écartés

  -- Les plages du sujet (FC 20-250, SpO2 50-100, Temp 30-45) sont des plages
  -- de PLAUSIBILITÉ : hors plage = donnée aberrante (capteur en panne,
  -- sentinelles 0/500), écartée en Silver. Ce ne sont PAS des seuils
  -- d'alerte clinique — ceux-ci sont définis en Gold
  -- (gold_pilotage.fact_monitoring : SpO2 < 92, FC < 50 ou > 100, Temp > 38,5).

  SELECT count() FROM bronze.monitoring;        -- 41778
  SELECT count() FROM silver.fact_monitoring;   -- 40920 (858 aberrants écartés)

  SELECT count() FROM silver.fact_monitoring
  WHERE heart_rate NOT BETWEEN 20 AND 250
     OR spo2 NOT BETWEEN 50 AND 100
     OR temp_c NOT BETWEEN 30.0 AND 45.0;
  -- doit être 0

  NOTE : la réadmission à 30 jours n'est plus calculée en Silver.
  C'est une règle métier, définie en Gold (gold_pilotage.fact_sejour,
  testée dans tests-gold.md §3). Silver nettoie, Gold interprète.

  5. Le chapitre CIM-10 ne retombe jamais sur 'Autre'

  SELECT code_cim10, chapitre FROM silver.dim_pathologie ORDER BY code_cim10;
  -- aucune ligne ne doit avoir chapitre = 'Autre'

  6. L'âge au diagnostic est plausible

  SELECT min(age_au_diagnostic), max(age_au_diagnostic)
  FROM silver.fact_diagnostic;
  -- attendu : min >= 0 et max <= ~110
