"""
ÉTAPE 0 — COPIE VERS LE LAKE ET PSEUDONYMISATION

Transformations appliquées ici :
  - patient_id → HMAC-SHA256(patient_id, sel) = patient_pseudo
  - nom, prenom, nir → supprimés
  - birth_date → birth_year (seulement l'année)
  - sex → normalisé en 'M'/'F' (minuscule, valeurs inattendues → '?')

Les fichiers sans PII (diagnostics, monitoring, référentiels) sont copiés
tels quels. L'opération est idempotente : si le fichier lake existe déjà,
on ne le recalcule pas car on aurait le meme résultat

Écritures atomiques (résilience aux crashs) :
  Chaque fichier est d'abord écrit dans un compagnon .tmp, puis renommé
  vers son nom final via os.replace (atomique sur POSIX). Conséquence :
  soit le fichier définitif est complet, soit il n'existe pas. Un crash
  en cours d'écriture ne laisse jamais de fichier tronqué qui serait
  ensuite considéré comme "déjà présent" et jamais retenté.

Pourquoi HMAC-SHA256 et pas SHA256 simple ?
  SHA256(patient_id) sans sel permet une attaque par dictionnaire :
  un attaquant qui connaît la liste des IPP peut retrouver tous les pseudos.
  HMAC avec sel secret rend cette attaque impossible sans le sel.
"""
import csv
import hashlib
import hmac
import json
import os
import shutil
from pathlib import Path

import pyarrow.parquet as pq

from . import config


def _tmp_path(dst: Path) -> Path:
    """Chemin temporaire compagnon dans le même répertoire.

    Même répertoire = même système de fichiers → os.replace est
    garanti atomique par le noyau (rename(2) POSIX).
    """
    return dst.with_name(dst.name + ".tmp")


def _atomic_copy(src: Path, dst: Path) -> None:
    """Copie src → dst de manière atomique via .tmp + os.replace."""
    tmp = _tmp_path(dst)
    shutil.copy2(src, tmp)
    os.replace(tmp, dst)


def _pseudonymize(patient_id: str) -> str:
    """HMAC-SHA256 déterministe : même patient_id → toujours même pseudo.

    Déterministe = le même patient_id produit toujours le même hash,
    ce qui permet de faire des jointures entre tables (séjours ↔ patients)
    sans jamais manipuler l'identifiant réel.
    """
    return hmac.new(config.PIPELINE_SALT, patient_id.encode(), hashlib.sha256).hexdigest()


def _normalize_sex(raw: str) -> str:
    """Normalise le sexe en 'M' ou 'F'. '?' si valeur inconnue.

    Les sources hospitalières encodent le sexe de manières variées
    ('M', 'MASCULIN', '1'...). On normalise ici pour éviter d'avoir
    à gérer ces variantes dans toutes les couches suivantes.
    """
    val = raw.strip().upper()
    if val in ("M", "MASCULIN", "MALE", "1"):
        return "M"
    if val in ("F", "FEMININ", "FÉMININ", "FEMALE", "2"):
        return "F"
    return "?"


def _copy_patients(date_str: str) -> int:
    src = config.SOURCE_DIR / "patients" / date_str / "patients.csv"
    dst = config.LAKE_DIR  / "patients" / date_str / "patients.csv"

    # Idempotence : si le fichier lake existe déjà, on ne le recrée pas.
    # Cela garantit que la pseudonymisation n'est faite qu'une fois par date,
    # et que le pipeline peut être relancé sans effet de bord.
    if dst.exists():
        return 0

    dst.parent.mkdir(parents=True, exist_ok=True)
    tmp = _tmp_path(dst)
    count = 0

    # Écriture d'abord dans .tmp : si le processus meurt avant os.replace,
    # dst n'existe toujours pas et le prochain run reprendra la date.
    with open(src, newline="") as fin, open(tmp, "w", newline="") as fout:
        reader = csv.DictReader(fin)
        # Colonnes de sortie : PII supprimées, birth_date réduite à birth_year.
        # La généralisation birth_date → birth_year réduit la précision
        # juste assez pour empêcher la ré-identification, tout en conservant
        # l'information utile pour les analyses démographiques (âge, cohortes).
        writer = csv.DictWriter(
            fout,
            fieldnames=["patient_pseudo", "birth_year", "sex", "region_code"],
        )
        writer.writeheader()
        for row in reader:
            writer.writerow({
                "patient_pseudo": _pseudonymize(row["patient_id"]),
                "birth_year":     int(row["birth_date"][:4]),  # "1985-03-12" → 1985
                "sex":            _normalize_sex(row["sex"]),
                "region_code":    row["region_code"].strip(),
                # SUPPRIMÉS : patient_id, nom, prenom, nir, birth_date
            })
            count += 1

    os.replace(tmp, dst)
    return count


def _copy_sejours(date_str: str) -> int:
    src = config.SOURCE_DIR / "sejours" / date_str / "sejours.csv"
    dst = config.LAKE_DIR  / "sejours" / date_str / "sejours.csv"
    if dst.exists():
        return 0

    dst.parent.mkdir(parents=True, exist_ok=True)
    tmp = _tmp_path(dst)
    count = 0

    with open(src, newline="") as fin, open(tmp, "w", newline="") as fout:
        reader = csv.DictReader(fin)
        # patient_id remplacé par patient_pseudo avec le MÊME sel que pour patients.
        # C'est ce qui rend les jointures possibles en Silver :
        # HMAC(patient_id, sel) donne le même résultat dans les deux tables.
        writer = csv.DictWriter(
            fout,
            fieldnames=[
                "stay_id", "patient_pseudo", "service_code",
                "admission_ts", "discharge_ts",
                "admission_mode", "discharge_mode",
            ],
        )
        writer.writeheader()
        for row in reader:
            writer.writerow({
                "stay_id":        row["stay_id"],
                "patient_pseudo": _pseudonymize(row["patient_id"]),
                "service_code":   row["service_code"],
                "admission_ts":   row["admission_ts"],
                "discharge_ts":   row["discharge_ts"],  # vide si séjour en cours
                "admission_mode": row["admission_mode"],
                "discharge_mode": row["discharge_mode"],
            })
            count += 1

    os.replace(tmp, dst)
    return count


def _copy_diagnostics(date_str: str) -> int:
    src = config.SOURCE_DIR / "diagnostics" / date_str / "diagnostics.json"
    dst = config.LAKE_DIR  / "diagnostics" / date_str / "diagnostics.json"
    if dst.exists():
        return 0

    dst.parent.mkdir(parents=True, exist_ok=True)
    # Copie brute : les diagnostics ne contiennent pas de PII (seulement stay_id).
    # Le stay_id n'est pas un identifiant direct du patient — il ne permet pas
    # de retrouver l'identité sans passer par la table séjours pseudonymisée.
    _atomic_copy(src, dst)

    with open(dst) as f:
        return len(json.load(f))


def _copy_monitoring(date_str: str) -> int:
    src = config.SOURCE_DIR / "monitoring" / date_str / "monitoring.parquet"
    dst = config.LAKE_DIR  / "monitoring" / date_str / "monitoring.parquet"
    if dst.exists():
        return 0

    dst.parent.mkdir(parents=True, exist_ok=True)
    # Copie brute : le monitoring ne contient que stay_id + constantes vitales.
    # Pas de PII, pas de transformation nécessaire.
    _atomic_copy(src, dst)

    t = pq.read_table(dst)
    return t.num_rows


def copy_referentiels() -> None:
    """Les référentiels sont déposés une seule fois par le CHU (J0). Copie idempotente."""
    ref_src = config.SOURCE_DIR / "referentiels"
    ref_dst = config.LAKE_DIR  / "referentiels"
    ref_dst.mkdir(parents=True, exist_ok=True)

    # On prend le dossier le plus ancien disponible dans la source
    # (les référentiels sont déposés au jour J0, ils ne changent pas ensuite).
    date_dirs = sorted(ref_src.iterdir())
    if not date_dirs:
        return

    src_dir = date_dirs[0]
    for f in src_dir.glob("*.csv"):
        dst_file = ref_dst / f.name
        if not dst_file.exists():
            _atomic_copy(f, dst_file)


def copy_date_to_lake(date_str: str) -> dict:
    """
    Copie et pseudonymise tous les fichiers d'une date vers le lake.
    Retourne un dict avec le nombre de lignes copiées par source.
    Idempotent : si les fichiers lake existent déjà, rien n'est fait.
    """
    return {
        "patients":    _copy_patients(date_str),
        "sejours":     _copy_sejours(date_str),
        "diagnostics": _copy_diagnostics(date_str),
        "monitoring":  _copy_monitoring(date_str),
    }
