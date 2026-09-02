# Tests de la couche Gold

Valeurs attendues mesurées sur le jeu de données fourni (28 jours : 2026-08-01 → 28).
Les requêtes admin se lancent depuis http://localhost:8123/play.

---

## 1. Toutes les vues répondent

```sql
-- Pilotage : 4 vues d'exposition + 8 vues KPI
SELECT count() FROM gold_pilotage.v_sejours_en_cours;              -- 683
SELECT count() FROM gold_pilotage.v_alertes_par_service;           -- 2
SELECT count() FROM gold_pilotage.v_taux_readmission_30j;          -- 1 (vue GLOBALE)
SELECT count() FROM gold_pilotage.v_mortalite;                     -- 24
SELECT count() FROM gold_pilotage.v_dms_par_service_mois;          -- 16
SELECT count() FROM gold_pilotage.v_data_freshness;                -- 1

-- Recherche
SELECT count() FROM gold_recherche.fact_diagnostic;                -- 12713
SELECT count() FROM gold_recherche.v_prevalence_pathologies;       -- 11
SELECT count() FROM gold_recherche.v_prevalence_mensuelle;         -- 16
SELECT count() FROM gold_recherche.v_description_cohorte;          -- 136
SELECT count() FROM gold_recherche.v_comorbidites;                 -- 36
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
-- les deux doivent être égaux (683)
```

## 3. Réadmission à 30 jours — indicateur GLOBAL

La règle métier (sortie précédente du même patient entre 1 et 30 jours avant
l'admission) est définie dans `gold_pilotage.fact_sejour`, PAS en Silver :
Silver nettoie, Gold porte les règles métier.

```sql
SELECT * FROM gold_pilotage.v_taux_readmission_30j;
-- nb_sejours = 6729 | nb_readmissions = 780 | taux_readmission_pct = 11.6

-- Cohérence avec la fact au grain séjour :
SELECT count(), sum(is_readmission_30j) FROM gold_pilotage.fact_sejour;
-- 6729 | 780
```

Deux points de méthode, vérifiés sur les données :

- **Tous les séjours comptent au dénominateur**, y compris les 683 en cours :
  la réadmission se juge à l'admission, peu importe que le nouveau séjour soit
  terminé. Filtrer sur `date_sortie IS NOT NULL` donnerait 637/6046 = 10,5 % en
  écartant à tort 143 réadmissions actuellement hospitalisées.
- La fenêtre `lagInFrame` (séjour précédent immédiat) donne le même résultat
  qu'un self-join exhaustif « n'importe quel séjour antérieur sorti dans les
  1-30 jours » (780 dans les deux cas) : pas de séjours imbriqués dans ce jeu
  de données.

## 4. Mortalité — couverture élargie

```sql
-- v_mortalite couvre TOUS les séjours terminés, pas seulement les urgences :
-- son total de décès doit être supérieur à celui de v_activite_urgences.
SELECT sum(nb_deces) FROM gold_pilotage.v_mortalite;          -- 995
SELECT sum(nb_deces) FROM gold_pilotage.v_activite_urgences;  -- 206
```

L'écart chiffre l'angle mort corrigé : **789 décès sur 995 (79 %)** surviennent
hors du service des urgences et n'apparaissaient nulle part dans le pilotage.

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

Sur ce jeu de données il est **réellement actif** : la plus petite cohorte fait
3 patients, deux codes CIM-10 passent sous le seuil de 5.

```sql
SELECT count() FROM silver.fact_diagnostic;          -- 12720
SELECT count() FROM gold_recherche.fact_diagnostic;  -- 12713 (7 lignes écartées)

SELECT uniqExact(code_cim10) FROM silver.fact_diagnostic;          -- 13
SELECT uniqExact(code_cim10) FROM gold_recherche.fact_diagnostic;  -- 11
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
SELECT count() FROM silver.fact_diagnostic;    -- 12720
SELECT count() FROM bronze.sejours
  WHERE discharge_ts IS NOT NULL AND discharge_ts < admission_ts;  -- 68
SELECT count() FROM silver.sejours_stg
  WHERE discharge_ts IS NOT NULL AND discharge_ts < admission_ts;  -- 0
```

## 11. Monitoring — nettoyage Silver vs alertes cliniques Gold

Deux notions à ne pas confondre, testables séparément :

**Nettoyage (Silver)** — les plages du sujet (FC 20-250, SpO2 50-100,
Temp 30-45) sont des plages de plausibilité physiologique. Hors plage =
donnée aberrante (capteur en panne, sentinelles 0/500 pour la FC) → écartée.

```sql
SELECT count() FROM bronze.monitoring;         -- 41778
SELECT count() FROM silver.fact_monitoring;    -- 40920 (858 relevés aberrants écartés)

-- Plus aucune valeur aberrante en Silver :
SELECT count() FROM silver.fact_monitoring
WHERE heart_rate NOT BETWEEN 20 AND 250
   OR spo2 NOT BETWEEN 50 AND 100
   OR temp_c NOT BETWEEN 30 AND 45;            -- 0
```

**Alertes cliniques (Gold)** — règle métier définie dans
`gold_pilotage.fact_monitoring` :
SpO2 < 92 % (désaturation) | FC < 50 ou > 100 bpm (brady/tachycardie) |
Temp > 38,5 °C (fièvre).

```sql
SELECT
  sum(is_alerte)                AS nb_alertes,            -- 3314
  sum(alerte_desaturation)      AS nb_desaturations,      -- 1127
  sum(alerte_brady_tachycardie) AS nb_brady_tachycardies, -- 1105
  sum(alerte_fievre)            AS nb_fievres             -- 1082
FROM gold_pilotage.fact_monitoring;
```

Un même relevé peut franchir plusieurs seuils : la somme des trois colonnes
(3314) peut dépasser `nb_alertes` — ici elle lui est égale car aucun relevé
ne cumule deux seuils sur ce jeu de données.
