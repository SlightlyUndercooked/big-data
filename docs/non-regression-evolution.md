# Non-régression — évolution 2026-08-29

Contrôle que l'ajout des actes et de la description des services n'a
dégradé aucun indicateur existant.

## Ce qui a été fait, et l'erreur de méthode à ne pas reproduire

Une baseline a bien été capturée avant toute modification, mais **contre
la base telle qu'elle était déployée** — c'est-à-dire les vues issues du
dernier run du pipeline, pas le code présent dans le dépôt. Or le working
tree contenait des modifications non commitées (refactor de
`fact_monitoring`) qui n'avaient pas encore été appliquées à ClickHouse.
La comparaison mesurait donc en partie ce refactor, et non l'évolution.

**Règle pour le prochain cycle : capturer la baseline APRÈS un run du
pipeline sur le code courant, jamais avant.**

Le contrôle ci-dessous ne repose donc pas sur cette comparaison, mais sur
une preuve structurelle : montrer qu'aucune définition d'objet existant
n'a été modifiée, hors une modification strictement additive.

## Preuve — objets redéfinis depuis le dernier commit

```bash
git diff 71a9ad9 -- eds-chu/sql/ | grep -E "^\+CREATE OR REPLACE"
```

| Objet redéfini | Nature | Auteur |
|---|---|---|
| `gold_pilotage.fact_monitoring` | modifié (INNER JOIN vers fact_sejour) | refactor présent dans le working tree **avant** l'évolution |
| `silver.dim_service` | **additif** : 4 colonnes ajoutées | évolution |
| `silver.dim_ccam` | nouveau | évolution |
| `silver.fact_acte` | nouveau | évolution |
| `gold_pilotage.dim_ccam` | nouveau | évolution |
| `gold_pilotage.fact_acte` | nouveau | évolution |
| `gold_pilotage.v_activite_par_categorie` | nouveau | évolution |
| `gold_pilotage.v_activite_par_pole` | nouveau | évolution |
| `gold_pilotage.v_actes_par_service` | nouveau | évolution |
| `gold_pilotage.v_actes_par_type` | nouveau | évolution |
| `gold_pilotage.v_densite_actes_par_lit` | nouveau | évolution |
| `gold_pilotage.v_montant_facture_par_service` | nouveau | évolution |

Aucun autre objet n'est redéfini. Les vues KPI existantes (DMS,
urgences, réadmission, mortalité, séjours en cours, prévalence,
cohorte, comorbidités) ont une définition **inchangée au caractère près**.

### `silver.dim_service` : la seule modification d'un objet existant

Elle est additive. Les colonnes d'origine sont conservées à l'identique,
quatre colonnes s'ajoutent (`categorie`, `pole`, `capacite_lits`,
`description_manquante`), et le nombre de lignes ne bouge pas :

```sql
SELECT count() AS n, uniqExact(service_code) AS codes FROM silver.dim_service;
-- 8	8  (8 services, inchangé)
```

Le LEFT JOIN garantit qu'aucun service ne disparaît même si le
référentiel descriptif est incomplet — c'est le cas de NEURO.

## Valeurs de référence après évolution

À utiliser comme baseline du prochain cycle.

| Indicateur | Valeur |
|---|---:|
| bronze.sejours | 6797 |
| bronze.monitoring | 41778 |
| bronze.actes | 8112 |
| silver.dim_patient | 6000 |
| silver.dim_service | 8 |
| silver.fact_sejour | 6729 |
| silver.fact_diagnostic | 12593 |
| silver.fact_monitoring | 40920 |
| silver.fact_acte | 8030 |
| Réadmissions 30j | 780 |
| Décès (séjours terminés) | 995 |
| Séjours en cours | 683 |
| Mesures monitoring exposées | 40400 |
| Alertes cliniques | 3270 |
| Prévalence pathologies | 11 lignes |
| Comorbidités | 36 lignes |
| fact_diagnostic exposé | 12586 |

## À signaler — écart imputable au refactor antérieur

`gold_pilotage.fact_monitoring` est passée de `FROM silver.fact_monitoring`
à un `INNER JOIN silver.fact_sejour`, pour rattacher `service_code`. La
jointure écarte les relevés dont le séjour est absent de `fact_sejour` :

```sql
SELECT count() FROM silver.fact_monitoring
WHERE stay_id NOT IN (SELECT stay_id FROM silver.fact_sejour);
-- 520
```

40 920 − 520 = 40 400 mesures exposées. L'écart est expliqué à la ligne
près, et le comportement est cohérent avec le reste du modèle :
`fact_diagnostic` et `fact_acte` écartent déjà leurs lignes orphelines de
la même façon. Ce changement n'appartient pas à l'évolution.

## Conclusion

Aucune régression imputable à l'évolution : aucune vue KPI existante n'a
été redéfinie, et la seule table existante modifiée l'a été de façon
strictement additive.
