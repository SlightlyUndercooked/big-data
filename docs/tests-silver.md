
  1. Les séjours incohérents ont bien été écartés

  -- Bronze doit avoir 136, Silver doit avoir 0
  SELECT count() FROM bronze.sejours
  WHERE discharge_ts IS NOT NULL AND discharge_ts < admission_ts;

  SELECT count() FROM silver.sejours_clean
  WHERE discharge_ts IS NOT NULL AND discharge_ts < admission_ts;

  2. La déduplication patients a bien fonctionné

  -- Bronze : 16200, Silver : doit être < 16200
  SELECT count() FROM bronze.patients;
  SELECT count() FROM silver.dim_patient;

  -- Vérifier qu'il n'y a plus de doublons
  SELECT patient_pseudo, count() AS nb
  FROM silver.dim_patient
  GROUP BY patient_pseudo
  HAVING nb > 1;
  -- doit retourner 0 lignes

  3. Les diagnostics orphelins ont bien été écartés

  -- Silver doit être < Bronze (37380)
  SELECT count() FROM bronze.diagnostics;
  SELECT count() FROM silver.fact_diagnostic;

  -- Aucun diagnostic ne doit pointer vers un séjour absent de sejours_clean
  SELECT count() FROM silver.fact_diagnostic f
  WHERE f.stay_id NOT IN (SELECT stay_id FROM silver.sejours_clean);
  -- doit retourner 0

  4. Les réadmissions sont calculées

  SELECT count() FROM silver.fact_sejour WHERE is_readmission_30j = 1;
  -- doit être > 0

  -- Vérifier un exemple : un patient avec plusieurs séjours
  SELECT patient_pseudo, date_admission, date_sortie, is_readmission_30j
  FROM silver.fact_sejour
  WHERE patient_pseudo IN (
      SELECT patient_pseudo FROM silver.fact_sejour
      GROUP BY patient_pseudo HAVING count() > 1
      LIMIT 1
  )
  ORDER BY date_admission;

  5. Les alertes monitoring sont cohérentes

  SELECT sum(nb_alertes_monitoring) FROM silver.monitoring_alertes;
  -- doit être 1369

  -- Cohérence Bronze → Silver
  SELECT count() FROM bronze.monitoring
  WHERE heart_rate NOT BETWEEN 20 AND 250
     OR spo2 NOT BETWEEN 50 AND 100
     OR temp_c NOT BETWEEN 30.0 AND 45.0;
  -- doit aussi être 1369

  6. Le chapitre CIM-10 ne retombe jamais sur 'Autre'
  
  SELECT code_cim10, chapitre FROM silver.dim_pathologie ORDER BY code_cim10;
  -- aucune ligne ne doit avoir chapitre = 'Autre'
