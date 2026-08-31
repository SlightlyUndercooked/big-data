# Modèle de données — EDS CHU

Couche **Gold** de ClickHouse. Deux schémas en étoile indépendants, un par usage métier.

---

## Choix du star schema

On choisit le **schéma en étoile** plutôt qu'un schéma normalisé (3NF) ou en flocon (snowflake) pour plusieurs raisons :

- **Performance analytique** : ClickHouse est un moteur colonne taillé pour les agrégations massives. Avec un star schema, une requête `GROUP BY service_code` sur `fact_sejour` ne lit que les colonnes nécessaires sans jointure en cascade. Un schéma normalisé multiplierait les jointures et tuerait les performances sur de gros volumes.
- **Lisibilité pour Metabase** : les dashboards sont construits par des utilisateurs non-techniques (opérationnels, chercheurs). Une table de faits + quelques dimensions plates est bien plus navigable qu'un graphe de 10 tables normalisées.
- **Séparation claire fait / contexte** : la table de faits porte les mesures (durée, compteurs, flags), les dimensions portent le contexte (qui, quoi, quand). Ce découpage rend les indicateurs reproductibles et auditables.

On ne choisit pas le flocon (snowflake) car les dimensions sont simples et peu volumineuses : normaliser `dim_pathologie` en `dim_chapitre → dim_groupe → dim_cim10` n'apporterait que de la complexité sans gain de stockage significatif.

---

## Schéma 1 — Pilotage hospitalier

> **Grain de la table de faits : un séjour hospitalier**

```
                        ┌─────────────────────┐
                        │   dim_service        │
                        │─────────────────────│
                        │ service_code (PK)    │
                        │ libelle              │
                        │ pole                 │
                        └──────────┬──────────┘
                                   │
          ┌────────────────────────┼────────────────────────┐
          │                        │                        │
┌─────────┴──────────┐  ┌──────────▼──────────┐  ┌─────────┴──────────┐
│   dim_patient_pilot │  │   fact_sejour        │  │   dim_temps         │
│────────────────────│  │─────────────────────│  │────────────────────│
│ patient_pseudo (PK) │◄─┤ sejour_id (PK)      ├─►│ date_id (PK)        │
│ birth_year          │  │ patient_pseudo (FK)  │  │ date                │
│ sex                 │  │ service_code (FK)    │  │ annee               │
│ region_code         │  │ date_admission (FK)  │  │ mois                │
└─────────────────────┘  │ date_sortie (FK)     │  │ semaine             │
                         │ admission_mode       │  │ jour_semaine        │
                         │ discharge_mode       │  └─────────────────────┘
                         │ duree_sejour_jours   │
                         │ is_readmission_30j   │
                         │ nb_alertes_monitoring│
                         └─────────────────────┘
```

### Pourquoi ce grain ?

Le grain « un séjour » est le plus naturel pour le pilotage hospitalier : toutes les questions métier s'expriment à ce niveau (DMS *par séjour*, taux de réadmission = ratio de *séjours* suivant une sortie récente, activité urgences = nombre de *séjours* en urgence par jour). Un grain plus fin (journée de séjour, acte) rendrait les agrégations plus complexes sans valeur ajoutée pour ce tableau de bord. Un grain plus large (patient) effacerait la notion de passage, pourtant centrale en hôpital.

### Détail des tables

#### `fact_sejour`

| Colonne | Type | Description | Justification |
|---|---|---|---|
| `sejour_id` | String | Clé naturelle du séjour | Fourni par la source, stable, utilisé comme identifiant de jointure avec diagnostics |
| `patient_pseudo` | String | FK → dim_patient_pilot | Pseudonyme HMAC déterministe — permet de compter les réadmissions sans exposer l'identité |
| `service_code` | String | FK → dim_service | Code pivot vers le libellé et le pôle |
| `date_admission` | Date | FK → dim_temps | Tronqué à la date (sans heure) pour la jointure avec dim_temps ; l'horodatage complet est en Silver |
| `date_sortie` | Date | FK → dim_temps, NULL si séjour en cours | NULL est légitime (patient encore hospitalisé), pas une anomalie |
| `admission_mode` | String | urgence / programme / mutation | Dénormalisé dans la fact car c'est une mesure de contexte du séjour, pas une dimension stable à part entière — les valeurs sont peu nombreuses et ne changent pas |
| `discharge_mode` | String | domicile / mutation / transfert / deces / NULL | Idem |
| `duree_sejour_jours` | Float | Calculé en Silver : `discharge_ts - admission_ts` | Pré-calculé pour éviter de refaire le calcul à chaque requête dashboard ; Float pour capturer les fractions de journée |
| `is_readmission_30j` | Bool | Vrai si le patient a eu une sortie dans les 30j précédant cette admission | Indicateur qualité clé (sujet mentionne "taux de réadmission à 30j") ; calculé en Silver par fenêtre glissante sur `patient_pseudo` |
| `nb_alertes_monitoring` | Int | Nb de relevés monitoring hors plage physiologique sur ce séjour | Le monitoring est volumineux (flux continu) ; l'agréger ici évite d'exposer une table de plusieurs millions de lignes dans Gold. Le détail reste disponible en Silver si besoin d'analyse fine |

#### `dim_patient_pilot`

| Colonne | Type | Description | Justification |
|---|---|---|---|
| `patient_pseudo` | String | HMAC-SHA256(patient_id, sel_secret) | Déterministe : le même patient aura toujours le même pseudonyme, ce qui préserve les jointures inter-séjours. Non réversible : on ne peut pas retrouver le patient_id d'origine sans le sel, qui ne vit pas dans l'entrepôt |
| `birth_year` | Int | Année de naissance uniquement | RGPD art. 9 : la date complète est un quasi-identifiant. L'année seule suffit pour calculer une tranche d'âge ou une tendance démographique ; la précision supplémentaire du mois/jour n'apporte rien au pilotage |
| `sex` | String | M / F normalisé | Utile pour croiser l'activité par sexe ; normalisé en Silver (les sources peuvent avoir M/F, Masculin/Féminin, 1/2...) |
| `region_code` | String | Département de résidence | Utile côté pilotage pour visualiser la zone de chalandise du CHU ou comparer les flux par provenance géographique |

> `nom`, `prenom`, `nir`, `birth_date` complète ne sont **jamais** présents dans l'entrepôt. Ils sont supprimés dès la copie vers le lake, avant toute insertion en Bronze.

#### `dim_service`

| Colonne | Type | Justification |
|---|---|---|
| `service_code` | String | Clé de jointure avec fact_sejour |
| `libelle` | String | Indispensable pour des dashboards lisibles (un code seul n'a pas de sens pour un opérationnel) |
| `pole` | String | Permet d'agréger plusieurs services en unité de gestion (pôle médical). Pas dans les données source actuelles mais courant dans les référentiels hospitaliers réels ; à alimenter si le CHU fournit cette info |

#### `dim_temps`

La dimension temps est construite artificiellement (génération d'un calendrier), pas extraite d'une source. Elle permet de filtrer ou grouper sur n'importe quelle granularité temporelle sans recalcul à chaque requête.

| Colonne | Justification |
|---|---|
| `annee` | Agrégation annuelle (tendances) |
| `mois` | Saisonnalité, comparaisons mois sur mois |
| `semaine` | Pilotage opérationnel à la semaine |
| `jour_semaine` | Activité urgences : différencier lundi d'un dimanche |

---

## Schéma 2 — Recherche clinique

> **Grain de la table de faits : une occurrence de diagnostic sur un séjour**

```
                        ┌─────────────────────┐
                        │   dim_pathologie     │
                        │─────────────────────│
                        │ code_cim10 (PK)      │
                        │ libelle              │
                        │ chapitre             │
                        │ groupe               │
                        └──────────┬──────────┘
                                   │
          ┌────────────────────────┼────────────────────────┐
          │                        │                        │
┌─────────┴──────────┐  ┌──────────▼──────────┐  ┌─────────┴──────────┐
│  dim_patient_search │  │   fact_diagnostic    │  │   dim_temps         │
│────────────────────│  │─────────────────────│  │────────────────────│
│ patient_pseudo (PK) │◄─┤ diagnostic_id (PK)  ├─►│ date_id (PK)        │
│ birth_year          │  │ patient_pseudo (FK)  │  │ date                │
│ sex                 │  │ code_cim10 (FK)      │  │ annee               │
│ age_admission       │  │ sejour_id            │  │ mois                │
└─────────────────────┘  │ date_admission (FK)  │  │ semaine             │
                         │ type_diag            │  │ jour_semaine        │
                         │ service_code         │  └─────────────────────┘
                         └─────────────────────┘
```

### Pourquoi ce grain ?

Un séjour peut avoir plusieurs diagnostics (un principal + plusieurs associés). Si le grain était le séjour, on devrait stocker les codes CIM10 dans un tableau, ce qui empêche le filtre et l'agrégation par pathologie en SQL standard. En choisissant le grain « une ligne par diagnostic », on peut répondre directement à "combien de patients ont un code I25 (cardiopathie ischémique) ?" avec un simple `WHERE code_cim10 = 'I25'`, sans dépiler un tableau. C'est le grain naturel pour la recherche clinique.

### Détail des tables

#### `fact_diagnostic`

| Colonne | Type | Description | Justification |
|---|---|---|---|
| `diagnostic_id` | String | Concaténation `sejour_id\|\|'_'\|\|code_cim10` | Clé surrogate stable et reproductible ; pas de séquence auto-incrémentée car le pipeline est incrémental et distribué |
| `patient_pseudo` | String | FK → dim_patient_search | Même pseudonyme que côté pilotage — le sel est identique, donc le même patient_id produit le même hash dans les deux schémas. Cela permet une jointure autorisée entre les deux univers si un administrateur le décide, sans réidentification |
| `code_cim10` | String | FK → dim_pathologie | Pivot vers le libellé et la hiérarchie CIM-10 |
| `sejour_id` | String | Référence au séjour, **pas de FK formelle** | On ne crée pas de FK vers `fact_sejour` pour garder les deux schémas Gold indépendants (cloisonnement des droits). Un chercheur ne doit pas pouvoir naviguer vers les données de pilotage via une jointure. Si besoin d'un drill-through, il passe par une vue contrôlée |
| `date_admission` | Date | FK → dim_temps | Date d'entrée du séjour correspondant — permet de situer le diagnostic dans le temps sans dupliquer toute la table séjour |
| `type_diag` | String | principal / associe | Crucial pour la recherche : la prévalence d'une maladie se mesure sur les diagnostics **principaux** uniquement. Les associés représentent les comorbidités |
| `service_code` | String | Service lors du diagnostic | Dénormalisé (pas de FK vers dim_service) pour éviter une dépendance entre les schémas Gold. Permet quand même de filtrer par spécialité médicale côté recherche |

#### `dim_patient_search`

| Colonne | Type | Justification |
|---|---|---|
| `patient_pseudo` | String | Même logique que côté pilotage |
| `birth_year` | Int | Idem |
| `sex` | String | Idem |
| `age_admission` | Int | **Différence clé avec dim_patient_pilot** : l'âge au moment du séjour est la variable démographique fondamentale en recherche clinique (distribution d'âge d'une cohorte). On le calcule en Silver : `YEAR(admission_ts) - birth_year`. Il est stocké dans la dimension car il varie d'un séjour à l'autre pour le même patient |

> **Pourquoi pas `region_code` ici ?** Principe de minimisation RGPD : on ne conserve que ce qui est utile à l'usage. La région de résidence n'est pas pertinente pour décrire une cohorte de patients par pathologie. La conserver augmenterait le risque de ré-identification (croisement âge + sexe + région + maladie rare).

#### `dim_pathologie`

| Colonne | Justification |
|---|---|
| `code_cim10` | Code source brut fourni dans diagnostics.json |
| `libelle` | Texte lisible pour les dashboards chercheurs |
| `chapitre` | Niveau hiérarchique haut de la CIM-10 (ex : "Chapitre IX — Maladies de l'appareil circulatoire"). Permet de filtrer ou agréger par grande catégorie médicale sans connaître tous les codes |
| `groupe` | Sous-groupe intermédiaire (ex : "Cardiopathies ischémiques"). Utile pour des analyses à mi-chemin entre le code précis et le chapitre entier |

La hiérarchie chapitre/groupe est dénormalisée dans `dim_pathologie` (et non dans deux tables séparées) : c'est un choix de lisibilité assumé. Le référentiel CIM-10 est stable, son volume est petit (~10 000 codes), et la dénormalisation ne pose pas de problème de cohérence.

---

## Deux `dim_patient` séparées : pourquoi ?

C'est le choix de conception le plus important du modèle. On aurait pu faire une seule table `dim_patient` avec toutes les colonnes, partagée entre les deux schémas. On ne le fait pas pour deux raisons :

1. **Cloisonnement des droits** : si la table est partagée, un utilisateur du schéma recherche pourrait en théorie accéder à `region_code`, qui n'est pas supposé lui être visible. En dupliquant la dimension avec des colonnes différentes, le cloisonnement est structurel — il ne repose pas uniquement sur une règle Metabase qui pourrait être contournée.

2. **Minimisation RGPD** : chaque usage ne voit que les attributs dont il a besoin. Le pilotage a besoin de la région (flux géographiques) mais pas de l'âge précis à l'admission. La recherche a besoin de l'âge à l'admission mais pas de la région.

---

## Traitement du monitoring : pourquoi pas une table de faits dédiée ?

Le fichier `monitoring.parquet` est un flux continu de constantes (fréquence cardiaque, SpO2, température) mesuré régulièrement au chevet de chaque patient. Sur plusieurs jours de données, cela représente potentiellement des millions de lignes.

Exposer cette table brute dans Gold n'aurait pas de sens : un opérationnel ne peut pas analyser des millions de relevés individuels dans un dashboard. Ce qui l'intéresse, c'est **combien de fois les constantes sont sorties de la plage normale** pendant un séjour.

On agrège donc en Silver : `COUNT(*) WHERE hors_plage_physiologique GROUP BY stay_id` → une valeur entière `nb_alertes_monitoring` qui remonte dans `fact_sejour`. Le détail complet reste accessible en Silver pour des analyses ponctuelles (ex : visualiser l'évolution de la FC d'un patient sur un séjour).

---

## Règle petits effectifs (RGPD)

Toute agrégation côté recherche exposant une cohorte de **moins de 5 patients distincts** est supprimée du résultat avant restitution.

Implémentation : `HAVING COUNT(DISTINCT patient_pseudo) >= 5` sur toutes les requêtes d'agrégation du schéma recherche. Cette règle est appliquée au niveau des vues Gold (pas seulement dans Metabase) pour être effective quel que soit le client SQL.

---

## Cloisonnement des droits

| Schéma Gold | Groupe Metabase | Tables visibles |
|---|---|---|
| `gold_pilotage` | `operationnels` | fact_sejour, dim_patient_pilot, dim_service, dim_temps |
| `gold_recherche` | `chercheurs` | fact_diagnostic, dim_patient_search, dim_pathologie, dim_temps |

`dim_temps` est la seule table partagée — elle ne contient aucune donnée personnelle (c'est un calendrier).

---

## Vue d'ensemble des flux source → Gold

```
patients.csv       ──[pseudonymisation + suppression PII]──► dim_patient_pilot
                                                              dim_patient_search

sejours.csv        ──[contrôles qualité Silver]─────────────► fact_sejour

diagnostics.json   ──[dépliage JSON, 1 ligne/code]──────────► fact_diagnostic

monitoring.parquet ──[agrégation : COUNT hors plage]─────────► fact_sejour.nb_alertes_monitoring
                       (détail conservé en Silver)

referentiels/      ──[chargement direct]─────────────────────► dim_service
                                                               dim_pathologie
```
