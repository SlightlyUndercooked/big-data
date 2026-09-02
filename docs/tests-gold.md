# Tests de la couche Gold

Valeurs attendues mesurées sur le jeu de données fourni (3 jours : 2026-08-26 → 28).
Les requêtes admin se lancent depuis http://localhost:8123/play.

---

## 1. Toutes les vues répondent

```sql
-- Pilotage : 4 vues d'exposition + 9 vues KPI
SELECT count() FROM gold_pilotage.v_sejours_en_cours;              -- 1190
SELECT count() FROM gold_pilotage.v_alertes_par_service;           -- 2
SELECT count() FROM gold_pilotage.v_taux_readmission_par_service;  -- 8
SELECT count() FROM gold_pilotage.v_mortalite;                     -- 24
SELECT count() FROM gold_pilotage.v_dms_par_service_mois;          -- 16
SELECT count() FROM gold_pilotage.v_data_freshness;                -- 1

-- Recherche
SELECT count() FROM gold_recherche.fact_diagnostic;                -- 37040
SELECT count() FROM gold_recherche.v_prevalence_pathologies;       -- 10
SELECT count() FROM gold_recherche.v_prevalence_mensuelle;         -- 10
SELECT count() FROM gold_recherche.v_description_cohorte;          -- 200
SELECT count() FROM gold_recherche.v_comorbidites;                 -- 90
```

`v_alertes_par_service` ne renvoie que **2 lignes** et c'est normal : le flux
monitoring ne couvre que deux services (REA et CARDIO). Vérification :

```sql
SELECT uniqExact(f.service_code)
FROM silver.fact_monitoring m
INNER JOIN silver.fact_sejour f ON m.stay_id = f.stay_id;
-- doit être 2
```

## 2. Séjours en cours = séjours sans date de sortie

```sql
SELECT count() FROM silver.fact_sejour WHERE date_sortie IS NULL;
SELECT count() FROM gold_pilotage.v_sejours_en_cours;
-- les deux doivent être égaux (1190)
```

## 3. Cohérence des réadmissions global / par service

```sql
-- Le total par service doit égaler le total global
SELECT sum(nb_readmissions) FROM gold_pilotage.v_taux_readmission_par_service;
SELECT sum(nb_readmissions) FROM gold_pilotage.v_taux_readmission_30j;
-- doivent être égaux
```

## 4. Mortalité — couverture élargie

```sql
-- v_mortalite couvre TOUS les modes d'admission, pas seulement l'urgence :
-- son total de décès doit être supérieur à celui de v_activite_urgences.
SELECT sum(nb_deces) FROM gold_pilotage.v_mortalite;          -- 1996
SELECT sum(nb_deces) FROM gold_pilotage.v_activite_urgences;  --  681
```

L'écart chiffre l'angle mort corrigé : avant cette vue, `nb_deces` n'existait que
dans `v_activite_urgences`, filtrée sur `admission_mode = 'urgence'`. **1315 décès
sur 1996 (66 %)** — ceux survenus lors de séjours programmés ou de mutations —
n'apparaissaient nulle part dans le pilotage.

## 5. Fraîcheur des données

```sql
SELECT * FROM gold_pilotage.v_data_freshness;
-- derniere_date_source = 2026-08-28
-- nb_runs_error        = 0
-- anciennete_jours     croît chaque jour sans nouveau dépôt
```

## 6. RGPD — la fuite `diagnostic_id` est refermée

`silver.fact_diagnostic.diagnostic_id` vaut `concat(stay_id, '_', code_cim10, '_', type_diag)`.
Il exposait donc le `stay_id` en clair, récupérable par `splitByChar`, alors même
que le commentaire de la vue affirmait le contraire. La colonne a été retirée.

```sql
-- Doit ÉCHOUER en UNKNOWN_IDENTIFIER
SELECT diagnostic_id FROM gold_recherche.fact_diagnostic LIMIT 1;

-- Colonnes réellement exposées : 5, aucune ne permet de remonter au séjour
SELECT * FROM gold_recherche.fact_diagnostic LIMIT 1;
-- patient_pseudo, code_cim10, type_diag, age_au_diagnostic, mois_admission
```

## 7. RGPD — règle des petits effectifs appliquée à la table de faits

Le filtre `code_cim10 IN (... HAVING uniqExact(patient_pseudo) >= 5)` empêche
de contourner les `HAVING >= 5` des vues KPI en réagrégeant la fact brute.

Sur ce jeu de données il n'écarte rien (la plus petite cohorte fait 2689 patients).
Pour vérifier qu'il est fonctionnel et non inerte, rejouer sa logique avec un
seuil artificiellement haut :

```sql
SELECT count() AS lignes, uniqExact(code_cim10) AS codes
FROM silver.fact_diagnostic
WHERE code_cim10 IN (
    SELECT code_cim10 FROM silver.fact_diagnostic
    GROUP BY code_cim10 HAVING uniqExact(patient_pseudo) >= 2700
);
-- attendu : 26072 lignes, 7 codes (sur 10) → le filtre écarte bien
```

## 8. RGPD — aucune vue recherche ne diffuse de cohorte < 5

```sql
SELECT min(nb_patients) FROM gold_recherche.v_prevalence_pathologies;  -- >= 5
SELECT min(nb_patients) FROM gold_recherche.v_prevalence_mensuelle;    -- >= 5
SELECT min(nb_patients) FROM gold_recherche.v_description_cohorte;     -- >= 5
SELECT min(nb_patients) FROM gold_recherche.v_comorbidites;            -- >= 5
```

## 9. Cloisonnement des accès (le test qui compte)

À lancer depuis `eds-chu/`, avec les mots de passe du `.env`.

```bash
PIL="http://eds_pilotage:$GOLD_PILOTAGE_PASSWORD@localhost:8123/"
REC="http://eds_recherche:$GOLD_RECHERCHE_PASSWORD@localhost:8123/"
q(){ curl -s -G "$1" --data-urlencode "query=$2"; }

# Chaque compte ne voit QUE sa base
q "$PIL" "SHOW DATABASES"   # → gold_pilotage  (et rien d'autre)
q "$REC" "SHOW DATABASES"   # → gold_recherche (et rien d'autre)

# Les 7 requêtes suivantes doivent TOUTES renvoyer ACCESS_DENIED
q "$REC" "SELECT count() FROM gold_pilotage.fact_sejour"
q "$REC" "SELECT count() FROM silver.fact_sejour"
q "$REC" "SELECT count() FROM bronze.patients"
q "$REC" "SELECT count() FROM meta.pipeline_runs"
q "$PIL" "SELECT count() FROM gold_recherche.fact_diagnostic"
q "$PIL" "SELECT count() FROM silver.dim_patient"
q "$PIL" "SELECT count() FROM bronze.sejours"
```

Résultat obtenu : les 7 requêtes échouent en `ACCESS_DENIED`, et chaque compte
ne liste que sa propre base.

Les vues restent lisibles malgré l'absence de droits sur `silver` grâce à
`DEFINER = CURRENT_USER SQL SECURITY DEFINER` (cf. en-tête de `gold_pilotage.sql`).

## 10. Idempotence

```bash
python -m pipeline.run   # deux fois de suite
```

Le second run doit afficher « Aucune nouvelle date en Bronze », reconstruire
Silver/Gold et réappliquer les droits, sans modifier les comptages :

```sql
SELECT count() FROM silver.dim_patient;        -- 6000
SELECT count() FROM silver.fact_diagnostic;    -- 37040
SELECT count() FROM bronze.sejours
  WHERE discharge_ts IS NOT NULL AND discharge_ts < admission_ts;  -- 136
SELECT count() FROM silver.sejours_stg
  WHERE discharge_ts IS NOT NULL AND discharge_ts < admission_ts;  -- 0
```

---

## Limite connue — ventilation des alertes par constante

Dans `v_alertes_par_service`, les colonnes `nb_alertes_fc`, `nb_alertes_spo2` et
`nb_alertes_temp` sont dégénérées sur le jeu de données fourni :

```sql
SELECT
  countIf(heart_rate NOT BETWEEN 20 AND 250 AND spo2 BETWEEN 50 AND 100) AS fc_seule,
  countIf(spo2 NOT BETWEEN 50 AND 100 AND heart_rate BETWEEN 20 AND 250) AS spo2_seule,
  countIf(heart_rate NOT BETWEEN 20 AND 250 AND spo2 NOT BETWEEN 50 AND 100) AS les_deux,
  countIf(temp_c NOT BETWEEN 30.0 AND 45.0) AS temp
FROM silver.fact_monitoring;
-- obtenu : 0 | 0 | 1369 | 0
```

Les relevés anormaux portent **toujours simultanément** une FC et une SpO2 hors
plage (valeurs sentinelles 0 / 500 pour la FC, 0 / 120 pour la SpO2), jamais
l'une sans l'autre. La température reste dans `[36.4 ; 40.0]` sur tout le fichier,
donc toujours dans la plage physiologique `[30 ; 45]`.

La source ne modélise donc pas des dérives cliniques indépendantes mais des
**pannes de capteur** marquées par des valeurs sentinelles. Lecture correcte :
« ce flux ne contient aucune anomalie de température », et non « la température
n'est jamais anormale ». La ventilation est conservée car elle est juste et
redeviendra discriminante sur une source produisant des dérives indépendantes.
