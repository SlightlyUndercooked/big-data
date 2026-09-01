# Rapport Lake — EDS CHU

**Date de génération :** 2026-08-31  
**Source :** `source-filestorage/` (fourni par le CHU, lecture seule)  
**Destination :** `eds-chu/lake/`

---

## Rôle du Lake

Le Lake est la première couche de traitement. Son unique responsabilité est la **conformité RGPD** : supprimer les données à caractère personnel avant que quoi que ce soit ne touche la base de données. Aucune transformation métier n'est appliquée ici.

---

## Périmètre des données

| Source | Dates couvertes | Fichiers |
|---|---|---|
| `patients/` | 2026-08-26, 2026-08-27, 2026-08-28 | 3 CSV (un par jour) |
| `sejours/` | 2026-08-26, 2026-08-27, 2026-08-28 | 3 CSV |
| `diagnostics/` | 2026-08-26, 2026-08-27, 2026-08-28 | 3 JSON |
| `monitoring/` | 2026-08-26, 2026-08-27, 2026-08-28 | 3 Parquet |
| `referentiels/` | — (référentiel stable) | services.csv, cim10.csv |

---

## Volumétrie

### Patients

| Date | Lignes (en-tête exclue) |
|---|---|
| 2026-08-26 | 4 800 |
| 2026-08-27 | 5 400 |
| 2026-08-28 | 6 000 |
| **Total** | **16 200** |

Les dumps sont **cumulatifs** : chaque jour inclut les patients des jours précédents plus les nouveaux entrants. Ce n'est pas 16 200 patients distincts (la déduplication est faite en Silver).

### Séjours

| Date | Lignes |
|---|---|
| 2026-08-26 | 5 000 |
| 2026-08-27 | 5 000 |
| 2026-08-28 | 5 000 |
| **Total** | **15 000** |

### Diagnostics

| Date | Séjours porteurs | Codes CIM-10 |
|---|---|---|
| 2026-08-26 | 5 000 | 12 406 |
| 2026-08-27 | 5 000 | 12 492 |
| 2026-08-28 | 5 000 | 12 482 |
| **Total** | — | **37 380** |

Moyenne de 2,5 codes par séjour (diagnostic principal + comorbidités).

### Monitoring

| Date | Relevés de constantes |
|---|---|
| 2026-08-26 | 24 631 |
| 2026-08-27 | 22 190 |
| 2026-08-28 | 19 856 |
| **Total** | **66 677** |

Colonnes présentes dans chaque fichier Parquet : `stay_id`, `ts`, `heart_rate`, `spo2`, `temp_c`.

### Référentiels

| Fichier | Lignes (en-tête exclue) |
|---|---|
| `services.csv` | 8 |
| `cim10.csv` | 10 |

---

## Traitement RGPD appliqué

### Données supprimées

Les colonnes suivantes sont **absentes du Lake** — elles ne transitent jamais par la base de données :

| Champ source | Raison de suppression |
|---|---|
| `nom` | Donnée directement identifiante |
| `prenom` | Donnée directement identifiante |
| `nir` | Numéro de Sécurité Sociale — identifiant unique national |
| `birth_date` | Quasi-identifiant (date complète + sexe + région = combinaison ré-identificante) |
| `patient_id` | Identifiant interne CHU — remplacé par le pseudonyme |

### Pseudonymisation

`patient_id` est remplacé par un **pseudonyme HMAC-SHA256** :

```
patient_pseudo = HMAC-SHA256(patient_id, PIPELINE_SALT)
```

Propriétés garanties :
- **Déterministe** : le même `patient_id` produit toujours le même pseudonyme — les jointures inter-séjours et inter-dumps sont préservées.
- **Non réversible** : sans le sel (`PIPELINE_SALT`), on ne peut pas retrouver le `patient_id` d'origine. Le sel n'est jamais stocké dans la base de données.
- **Cohérent** : le même sel est appliqué aux patients et aux séjours — un séjour reste joinable à son patient via le pseudonyme.

### Vérification de conformité (résultats)

| Contrôle | Résultat |
|---|---|
| Colonnes `nom`, `prenom`, `nir`, `birth_date` absentes | ✓ Confirmé — colonnes absentes de tous les fichiers Lake |
| Format des pseudonymes (64 hex chars = SHA-256) | ✓ 0 pseudonyme mal formé sur les 4 800 lignes testées |
| `birth_year` uniquement (pas de date complète) | ✓ Plage 1930–2020, cohérente avec des patients vivants |
| Distribution des sexes normalisée (M/F) | ✓ M : 50,4 % / F : 49,6 % — aucune valeur aberrante |

### Données non modifiées

Les fichiers suivants ne contiennent aucune donnée personnelle et sont copiés à l'identique :

- `diagnostics.json` : codes CIM-10 et identifiants de séjours (pas de données patient directes)
- `monitoring.parquet` : mesures physiologiques liées à `stay_id` (pas de `patient_id`)
- `referentiels/` : données de nomenclature (services, pathologies)

---

## Structure des fichiers Lake

```
lake/
├── patients/
│   ├── 2026-08-26/patients.csv   # colonnes : patient_pseudo, birth_year, sex, region_code
│   ├── 2026-08-27/patients.csv
│   └── 2026-08-28/patients.csv
├── sejours/
│   ├── 2026-08-26/sejours.csv    # colonnes : stay_id, patient_pseudo, service_code,
│   │                             # admission_ts, discharge_ts, admission_mode,
│   │                             # discharge_mode
│   ├── 2026-08-27/sejours.csv
│   └── 2026-08-28/sejours.csv
├── diagnostics/
│   ├── 2026-08-26/diagnostics.json   # JSON imbriqué : [{stay_id, diagnostics: [{code_cim10, type}]}]
│   ├── 2026-08-27/diagnostics.json
│   └── 2026-08-28/diagnostics.json
├── monitoring/
│   ├── 2026-08-26/monitoring.parquet  # colonnes : stay_id, ts, heart_rate, spo2, temp_c
│   ├── 2026-08-27/monitoring.parquet
│   └── 2026-08-28/monitoring.parquet
└── referentiels/
    ├── services.csv    # service_code, service_label
    └── cim10.csv       # code_cim10, libelle
```
