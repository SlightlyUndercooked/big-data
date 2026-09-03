# Rapport Partie 1 : pipeline EDS-CHU et dashboards

Patron médaillon (lake → bronze → silver → gold) pour un EDS hospitalier.
Deux usages cloisonnés : **pilotage hospitalier** et **recherche clinique**.

Le modèle de données Gold (star schemas, grains, colonnes) est décrit à part :
[`modele-donnees.md`](modele-donnees.md). Les guides d'usage sont dans
[`guides/`](guides/lancement.md).

Période lue ici : activité du **1er au 28 août 2026** (jeu synthétique).
Les ordres de grandeur illustrent le dashboard ; un taux de mortalité à 16 %
n'est pas celui d'un CHU réel (signalé lorsque cela change nos choix)

---

## 1. Architecture et choix techniques

Les transformations métier sont en **SQL ClickHouse**, pas en pandas.
ClickHouse exécute les agrégations côté serveur, sur des colonnes, sans
charger l'entrepôt en mémoire Python. Python orchestre (copie lake,
chargement Bronze, exécution des fichiers SQL).

| Couche | Rôle                                | Idempotence                                            |
|--------|-------------------------------------|--------------------------------------------------------|
| Lake   | Conformité RGPD uniquement          | Fichier déjà présent → skip                            |
| Bronze | Dépôt brut + `_source_date`         | `meta.pipeline_runs` : date `success` jamais rechargée |
| Silver | Qualité, dédup, enrichissement      | `CREATE OR REPLACE TABLE` à chaque run                 |
| Gold   | Règles métier + KPI + cloisonnement | `CREATE OR REPLACE VIEW` à chaque run                  |

Silver et Gold sont toujours reconstruits : ils ne sont pas incrémentaux, contrairement au Bronze
Un bug corrigé en Silver se répercute au run suivant, et le silver utilise toujours la dernière version du Bronze.

Les dates source ne sont pas toutes présentes dans `patients/` (photo cumulative sur les 3 derniers jours seulement). Le pipeline fait l'union des dates de toutes les tables ; un fichier manquant pour une date est ignoré, pas une erreur.

---

## 2. Lake

Le lake retire les PII avant ClickHouse :

- supprimés : `nom`, `prenom`, `nir`, `birth_date`, `patient_id`
- conservés : `birth_year`, `sex` normalisé (`M`/`F`), `region_code`
- `patient_id` → HMAC-SHA256(`patient_id`, `PIPELINE_SALT`)

HMAC plutôt que SHA256 simple : sans le sel, une attaque par dictionnaire sur la liste des IPP est inefficace. Le sel n'est pas en base (`.env` seulement).
Le même sel est appliqué aux patients et aux séjours : les jointures restent possibles via `patient_pseudo`.

Diagnostics, monitoring et référentiels n'ont pas de PII directe : copie brute. Le `stay_id` n'identifie un patient qu'en passant par la table séjours déjà pseudonymisée.

---

## 3. Bronze

Bronze n'écarte rien. Les séjours incohérents (`discharge_ts` ≤ `admission_ts`) et les relevés capteur aberrants restent lisibles pour l'audit. Filtrer ici ferait disparaître la preuve de l'anomalie.

Chaque ligne porte `_source_date`. `meta.pipeline_runs` enregistre succès / erreur par date : c'est le journal RGPD du chargement et le mécanisme d'incrément.

Sur le jeu actuel (activité du 1er au 28 août 2026, photos patients les
26–28 août) :

| Table            | Lignes Bronze                        |
|------------------|--------------------------------------|
| patients         | 18 000 (3 dumps cumulatifs de 6 000) |
| sejours          | 6 797                                |
| diagnostics      | 12 720                               |
| monitoring       | 41 778                               |
| services / cim10 | 8 / 13                               |

Anomalies identifiées ici, traitées en Silver : 68 séjours temporellement incohérents ; 858 relevés hors plage de plausibilité.

---

## 4. Silver

Silver applique les contrôles qualité. Les règles métier (réadmission, seuils cliniques d'alerte) sont volontairement hors Silver : ce n'est pas de la qualité de donnée, c'est de l'interprétation clinique / gestion (donc en Gold)

| Règle                                                                    | Traitement                 |
|--------------------------------------------------------------------------|----------------------------|
| Patients : dump cumulatif                                                | 6 000 patients             |
| Sexe hors M/F                                                            | écarté                     |
| Sortie ≤ admission                                                       | écarté (68)                |
| Diagnostics d'un séjour invalide                                         | écartés                    |
| Monitoring hors plage physiologique (FC 20–250, SpO2 50–100, Temp 30–45) | écarté                     |
| Chapitre CIM-10                                                          | enrichi 1re lettre du code |

Résultat : `fact_sejour` 6 729 séjours, `fact_monitoring` 40 920 relevés plausibles, sans flag d'alerte.

---

## 5. Gold

Deux schémas ClickHouse, deux comptes (`eds_pilotage`, `eds_recherche`), `SELECT` uniquement sur sa base. Les vues lisent Silver grâce à `SQL SECURITY DEFINER` : elles s'exécutent avec les droits du pipeline, pas ceux de l'appelant. Un chercheur ne peut pas voir à travers la vue jusqu'à `stay_id` ou `region_code`

Côté recherche, il y a une minimisation supplémentaire : pas de `stay_id` (ni `diagnostic_id`, qui l'encapsulait), pas de `service_code`, date ramenée au mois, cohortes < 5 patients masquées dans les vues et dans la fact (un `HAVING` Metabase seul serait contournable en SQL).

Le détail des tables est dans [`modele-donnees.md`](modele-donnees.md).

---

## 6. Dashboard Pilotage

Public : direction, cadres de santé, DIM. Grain : **le séjour**.
Les quatre besoins du cahier (DMS, urgences, réadmission 30 j, constantes
en alerte) sont là. On y ajoute fraîcheur, tendance de DMS, mortalité,
séjours en cours : ce sont les vues qu'un établissement ouvre le matin
s'il a déjà les quatre premiers.

### Fraîcheur des données

Sans ça, un opérationnel ne sait pas si le pipeline a tourné. La vue lit`meta.pipeline_runs`. Visualisation table : quelques indicateurs scalaires côte à côte (dernière date source, ancienneté,
runs en erreur).

### DMS par service

![DMS par service](images/pilotage/dms_par_service.png)

La durée moyenne de séjour est l'indicateur d'occupation
le plus lu (T2A, lits, sorties). Un service qui s'allonge
bloque l'amont (urgences, bloc) ; un service trop court peut signaler
des sorties précoces. On le demande **par service** parce que comparer
la réa et les urgences n'a de sens que si chacun a sa propre cible.

Sur les séjours terminés uniquement (une durée
n'existe qu'à la sortie) :

| Service                | DMS  |
|------------------------|------|
| Réanimation            | ~9 j |
| Neurologie / oncologie | ~7 j |
| Pneumologie            | ~6 j |
| Cardiologie            | ~5 j |
| Chirurgie              | ~4 j |
| Pédiatrie              | ~3 j |
| Urgences               | ~2 j |

La hiérarchie est celle qu'un cadre attend : réa la plus longue, SAU
le plus court. C'est aussi un contrôle de vraisemblance du pipeline.
Barres horizontales : on compare des longueurs, pas des parts d'un tout
(un camembert n'a aucun sens ici).

La réa monopolise le lit le plus longtemps : c'est
là que le moindre jour gagné libère le plus de capacité. Les urgences à
2 jours confirment un rôle de passage, pas d'hospitalisation. Pour
piloter, on se fixe une cible par service (référentiel ATIH / interne)
et on ne juge un écart que contre cette cible — pas contre le voisin.

### DMS par service et par mois

![DMS par mois](images/pilotage/dms_par_service_par_mois.png)

La photo annuelle ne dit pas si un service se dégrade.
Le mois de sortie est la convention : on rattache la DMS au moment
où elle est connue.

Tous les services montent d'août à septembre. La réa
passe d'environ 8 j à près de 14 j.

On ne crie pas à la crise d'occupation. Septembre
n'est pas un mois plein : n'y figurent que les séjours assez longs pour
déborder d'août. C'est un biais de composition, pas (encore) la preuve
que « tout le monde s'allonge ». Le réflexe hôpital : attendre un mois
complet, puis comparer à N-1, pas à un bout de mois.

### Activité des urgences

![Urgences](images/pilotage/activite_urgences_par_jour.png)

Le SAU est le thermostat de l'établissement : un pic
d'un jour se paie en brancards, en DMS des lits d'aval, en heures
supplémentaires. On compte les passages dans le service URGENCES,
pas les admissions en mode « urgence ». Une admission urgence directe
en cardio n'est pas un passage SAU : la compter ici gonflerait
artificiellement l'activité du service et fausserait le dimensionnement
des équipes d'accueil.
Environ 40 à 70 passages par jour en août, pic
au-delà de 80 vers le 21. La chute après le 25 n'est pas une embellie :
c'est la fin du fichier source (28 août).
Le planning IDE / internat se cale sur la médiane
(~50–60) et le pic (~80), pas sur le 28 du mois. Un lundi à 80 passages
sans lits d'aval, c'est le tableau d'un encombrement, pas d'une
« bonne activité ».

### Taux de réadmission à 30 jours

C'est l'indicateur de qualité des soins du cahier,
pas un indicateur d'activité. Une réadmission précoce interroge la
sortie : traitement incomplet, éducation du patient, relais ville.
On le donne global, un seul chiffre. Le ventiler par le service
du nouveau séjour attribuerait la réadmission à celui qui réaccueille,
pas à celui qui a sorti — souvent un autre.

Fenêtre 1–30 jours après la sortie précédente
(`lagInFrame`). Le même jour = mutation, pas une réadmission. Tous
les séjours au dénominateur, y compris en cours : le critère se juge
à l'admission. Sur cette période : **11,6 %** (780 / 6 729).

1 séjour sur 9 est un retour à moins de 30 jours.
La direction pose deux questions, pas une : (1) est-ce comparable à
notre historique et au national ? (2) parmi ces retours, combien
étaient évitables (insuffisance cardiaque décompensée, plaie
opératoire) ? Le taux ouvre le dossier ; il ne le clôt pas.

### Alertes monitoring par jour

![Alertes par jour](images/pilotage/alertes_monitoring_par_jour.png)

Le cahier demande la surveillance des constantes :
combien de relevés en alerte par jour, en nombre, pas en %.
Les seuils sont cliniques (Gold), distincts du nettoyage Silver
(on a déjà jeté les capteurs à 0 ou 500) :

- SpO2 < 92 % → désaturation
- FC < 50 ou > 100 → brady / tachycardie
- Temp > 38,5 °C → fièvre

Trois courbes, pas de total sur le même axe : le total (flag `is_alerte`) est 3 fois plus haut et écrase les types. `is_alerte` reste en base pour compter des relevés sans double-comptage (un relevé fébrile et
désaturé = 1 relevé en alerte).
Avoir trois courbes distinctes (désaturation, brady/tachycardie, fièvre) permet de visualiser l'évolution de chaque type d’alerte, qui ne partagent ni la même fréquence ni la même signification médicale. Une seule courbe totale écraserait les différences. Par exemple un pic de fièvre serait invisible dans la masse des désaturations et inversement. Distinguer les types aide à cibler les actions correctives, alors qu’un total ne renseigne ni sur la nature du problème ni sur ses causes


### Alertes par service

![Alertes par service](images/pilotage/alertes_monitoring_par_service.png)

Savoir *combien* d'alertes sans savoir *où* ne permet
pas d'envoyer une équipe. Le monitoring source n'a pas de
`service_code` : le rattachement au séjour est fait en Gold.

Sur ce jeu, le volume se concentre en ardiologie
(~2 550 relevés en alerte) devant la réanimation (~750). Le mix
fièvre / rythme / désaturation est équilibré dans les deux services.

La cardio porte la charge de surveillance : soit
elle a plus de lits monitorés, soit les capteurs n'équipent pas le
reste de l'hôpital. Avant d'ouvrir des postes, on vérifie le
périmètre d'équipement. Un mix plat veut dire qu'on ne « traite » pas
qu'un seul type d'événement — le protocole d'escalade doit couvrir
les trois.

### Mortalité

![Mortalité](images/pilotage/mortalite_par_service_mode_admission.png)

Les décès n'existent dans le cahier que comme colonne
des urgences. Les laisser là rend invisibles les décès en programmé
ou en mutation. On ventile par service et mode d'admission :
la mortalité d'une réa en urgence et d'une chir réglée ne se
comparent pas (case-mix). Uniquement séjours terminés.

Taux global ~16 %. La pédiatrie en programmé sort
en tête (~22 %), devant la réa (~19 %).
On ne pilote pas un CHU réel avec ces taux.
16 % de mortalité hospitalière, et 22 % en pédiatrie programmée, sont
des artefacts du générateur. Sur un vrai entrepôt, la même vue
servirait à : (1) écarter les comparaisons urgence / programmé, (2)
ouvrir une revue de morbi-mortalité là où le taux sort de la cible
du service, (3) ne jamais classer les services sur un taux brut sans
ajustement au risque. Ici, elle sert surtout à montrer que le
pipeline calcule l'indicateur correctement — et qu'il faut lire le
chiffre avec le case-mix, pas comme un palmarès.

### Séjours en cours

C'est la liste du matin : qui est là, depuis combien
de jours, avec combien d'alertes, dans quel service. `discharge_ts`
NULL est légitime (patient encore hospitalisé). Ce n'est pas un
taux, c'est un fichier d'action.
Grain séjour, trié par ancienneté. `nb_alertes_monitoring`
est déjà agrégé sur la fact séjour : le cadre n'a pas à croiser
40 000 relevés.

Un séjour à 20 jours en médecine avec un
compteur d'alertes qui monte, c'est un appel à la visite, pas un
point au COPIL. La direction regarde le stock (combien de lits
encore occupés) ; le cadre de santé ouvre la ligne.

---

## 7. Dashboard Recherche

Public : épidémiologistes, investigateurs. Grain : **une occurrence
de diagnostic**. Objectif du cahier : tailles de cohortes et
description âge × sexe. On ajoute la tendance mensuelle et les
comorbidités : sans elles, on sait combien de diabétiques, pas
avec quoi ils rentrent, ni si ça bouge.

Les cohortes de moins de 5 patients distincts sont masquées (`HAVING`
et filtre sur la fact). Un chercheur ne reconstitue pas un cas rare
en réagrégeant la table.

### Prévalence des pathologies

![Prévalence](images/recherche/prevalence_pathologies.png)

Première question d'un EDS : « de quoi est faite notre
file active ? » La taille de cohorte = patients distincts, tous
types de diagnostics (principal et associé). Un diabétique
hospitalisé pour un infarctus appartient à la cohorte diabète : c'est
sa maladie chronique, même si ce n'est pas le motif d'entrée. Un
patient multi-pathologies compte dans chaque cohorte.

Quatre volumes dominent : infections urinaires
(~2 200 patients), diabète de type 2 (~2 150), insuffisance cardiaque
(~2 150), BPCO (~1 800). Plus loin : pneumonies, dépression,
appendicite, AVC. Mucoviscidose et trisomie 21 n'apparaissent pas
(`HAVING >= 5`).

L'eds de cet établissement, sur ce mois, est un
EDS de maladies chroniques de l'adulte plus que de maladies rares.
Un promoteur qui cherche 50 BPCO les trouvera ; un promoteur qui
cherche 5 mucoviscidoses devra passer par un registre, pas par cette
vue. Pour le DIM : IVU + IC + diabète, c'est le portrait d'une
médecine interne gériatrique — les essais et les parcours ville-hôpital
se calent là-dessus.

### Prévalence mensuelle

![Prévalence mensuelle](images/recherche/prevalence_mensuelle_par_pathologie.png)

La photo globale ne détecte ni saisonnalité (grippe,
bronchiolite) ni signal épidémique. Le seuil ≥ 5 s'applique à
chaque cellule mois × pathologie, pas au total : la somme des
mois n'égale pas le global, et c'est voulu.

On suit les mêmes grosses cohortes dans le temps,
sans faire réapparaître un code rare un mois donné.
Un chercheur qui voit une pente sur la BPCO
interroge un vrai changement (décompensation hivernale, recrutement)
avant de figer une cohorte d'essai. Un mois à 4 patients pour un
code fréquent est absent : on ne publie pas un effectif 4.

### Description de cohorte

![Cohorte](images/recherche/descriptions_cohorte.png)

Le cahier demande âge et sexe. Sans ça, on ne sait pas
si une cohorte « 2 000 diabétiques » est pédiatrique ou gériatrique —
le protocole n'est pas le même. Tranches de 10 ans plutôt que l'âge
exact (minimisation). Mêmes règles de comptage que la prévalence
(tous types de diagnostics), sinon les deux vues parleraient de
populations différentes.

Pyramide décalée vers les 50–80 ans, pic vers 60 ans
(~2 400 patients sur l'ensemble des codes affichés), sexes à peu près
équilibrés.
Les études menées sur cet EDS devront prévoir
des critères d'âge hauts, des interactions médicamenteuses, des
comorbidités — pas une cohorte d'adultes jeunes. Un essai pédiatrique
ne se nourrit pas de cette pyramide.

### Comorbidités

![Comorbidités](images/recherche/comorbidites_frequentes.png)

Paires (principal, associé) au sein d'un même séjour. La vue en table est plus pertinente est plus adaptée car il y a trop de combinaisons pour qu'un graphe soit lisible, et le chercheur peut filtrer par code.
`HAVING >= 5` est encore plus important ici car une combinaison rare de maladies est plus
identifiante qu'une pathologie isolée

---

## 8. Cloisonnement

Deux niveaux indépendants :

1. **ClickHouse** — `eds_pilotage` / `eds_recherche` n'ont `SELECT` que
   sur leur Gold (`step4_grants.py`). Bronze, Silver, `meta` et l'autre
   Gold → `ACCESS_DENIED`, y compris hors Metabase (port 8123).
2. **Metabase** — groupes `operationnels` / `chercheurs`, collections
   masquées. En OSS, « Blocked » (Enterprise) est remplacé par
   « no self-service » + collection `none`. Le niveau 1 reste la vraie
   serrure.

Les dashboards et droits applicatifs sont recréés par `python -m pipeline.metabase_setup` (idempotent). Procédure détaillée dans [`guides/metabase.md`](guides/metabase.md).
