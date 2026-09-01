# Rapport Bronze — EDS CHU

**Date de génération :** 2026-08-31  
**Source :** `eds-chu/lake/` (après pseudonymisation RGPD)  
**Destination :** ClickHouse — base `bronze`

---

## Rôle du Bronze

Le Bronze est le dépôt brut dans ClickHouse. Les données sont chargées **sans transformation métier** : ce qui est dans le lake arrive tel quel en Bronze, plus une colonne `_source_date` qui trace la date du fichier source. Toute anomalie constatée ici est conservée — c'est la Silver qui corrige.

---

## Traçabilité des chargements

| Lot | Date source | Statut | Lignes chargées |
|---|---|---|---|
| Référentiels | — | ✓ success | — |
| Bronze J1 | 2026-08-26 | ✓ success | 46 837 |
| Bronze J2 | 2026-08-27 | ✓ success | 45 082 |
| Bronze J3 | 2026-08-28 | ✓ success | 43 338 |

4 runs, 4 succès. Aucune date rechargée deux fois (contrôle `meta.pipeline_runs`).

---

## Volumétrie par table

### `bronze.patients`

| Date source | Lignes |
|---|---|
| 2026-08-26 | 4 800 |
| 2026-08-27 | 5 400 |
| 2026-08-28 | 6 000 |
| **Total** | **16 200** |

Les dumps sont cumulatifs (un patient présent le 26 réapparaît les 27 et 28). La déduplication est faite en Silver via `argMax(_source_date)`.

### `bronze.sejours`

| Date source | Lignes |
|---|---|
| 2026-08-26 | 5 000 |
| 2026-08-27 | 5 000 |
| 2026-08-28 | 5 000 |
| **Total** | **15 000** |

Plage des admissions : 2026-08-25 22:01 → 2026-08-28 21:59.

### `bronze.diagnostics`

| Date source | Codes CIM-10 |
|---|---|
| 2026-08-26 | 12 406 |
| 2026-08-27 | 12 492 |
| 2026-08-28 | 12 482 |
| **Total** | **37 380** |

### `bronze.monitoring`

| Date source | Relevés |
|---|---|
| 2026-08-26 | 24 631 |
| 2026-08-27 | 22 190 |
| 2026-08-28 | 19 856 |
| **Total** | **66 677** |

### Référentiels

| Table | Lignes |
|---|---|
| `bronze.services` | 8 services |
| `bronze.cim10` | 10 codes |

---

## Contrôles qualité

### Patients — anomalies détectées

| Contrôle | Résultat |
|---|---|
| Sexe hors `M`/`F` | **0** |
| `birth_year` hors plage 1900–2025 | **0** |
| `patient_pseudo` vide | **0** |

Aucune anomalie sur les patients. Les données sont propres à ce niveau.

### Séjours — anomalies détectées

| Contrôle | Nb de cas |
|---|---|
| `discharge_ts` < `admission_ts` (incohérence temporelle) | **136** |
| `discharge_ts` NULL (séjour en cours au moment du dump) | **1 190** |

Les 136 séjours avec une sortie antérieure à l'entrée sont une anomalie de saisie source. Ils seront **écartés en Silver** (`WHERE discharge_ts IS NULL OR discharge_ts > admission_ts`). Les 1 190 séjours sans date de sortie sont légitimes (patients encore hospitalisés) et conservés.

### Monitoring — relevés hors plage physiologique

| Constante | Plage normale | Relevés hors plage |
|---|---|---|
| `heart_rate` | 20–250 bpm | **1 369** |
| `spo2` | 50–100 % | **1 369** |
| `temp_c` | 30,0–45,0 °C | **0** |

Les 1 369 relevés hors plage représentent **2,05 %** du total (1 369 / 66 677). Ils sont conservés en Bronze (donnée brute), agrégés en Silver comme `nb_alertes_monitoring` par séjour, et exposés bruts dans `gold_pilotage.fact_monitoring` avec le flag `is_alerte = 1`.

---

## Distribution des modalités

### Modes d'admission (`bronze.sejours`)

| Mode | Séjours | % |
|---|---|---|
| urgence | 5 074 | 33,8 % |
| mutation | 4 981 | 33,2 % |
| programme | 4 945 | 33,0 % |

Distribution équilibrée entre les trois modes — cohérente avec un CHU de taille moyenne.

### Modes de sortie (`bronze.sejours`)

| Mode | Séjours | % |
|---|---|---|
| domicile | 5 867 | 39,1 % |
| NULL (séjour en cours) | 3 182 | 21,2 % |
| deces | 2 009 | 13,4 % |
| mutation | 1 971 | 13,1 % |
| transfert | 1 971 | 13,1 % |

Les 3 182 valeurs NULL correspondent aux séjours sans `discharge_ts` — les deux colonnes sont cohérentes entre elles.

### Répartition par service (`bronze.sejours`)

| Service | Séjours |
|---|---|
| ONCO | 1 961 |
| PNEUMO | 1 928 |
| REA | 1 914 |
| PEDIA | 1 910 |
| CHIR | 1 896 |
| URGENCES | 1 851 |
| CARDIO | 1 844 |
| NEURO | 1 696 |
| **Total** | **15 000** |

Distribution homogène entre les 8 services — aucun service surreprésenté.

---

## Synthèse

| Point | Statut |
|---|---|
| Chargement complet des 3 dates | ✓ |
| Traçabilité dans `meta.pipeline_runs` | ✓ 4/4 succès |
| Aucune date chargée deux fois | ✓ |
| Patients : données propres | ✓ 0 anomalie |
| Séjours : 136 incohérences temporelles identifiées | ⚠ traité en Silver |
| Monitoring : 1 369 relevés hors plage (2 %) | ⚠ flagués en Silver/Gold |
| Données PII absentes (vérifiées au Lake) | ✓ |
