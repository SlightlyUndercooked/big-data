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

Pourquoi HMAC-SHA256 et pas SHA256 simple ?
  SHA256(patient_id) sans sel permet une attaque par dictionnaire :
  un attaquant qui connaît la liste des IPP peut retrouver tous les pseudos.
  HMAC avec sel secret rend cette attaque impossible sans le sel.
"""
import csv
import hashlib
import hmac
import json
import shutil
from pathlib import Path

import pyarrow.parquet as pq

from . import config


def _pseudonymize(patient_id: str) -> str:
    """HMAC-SHA256 déterministe : même patient_id → toujours même pseudo."""
    return hmac.new(config.PIPELINE_SALT, patient_id.encode(), hashlib.sha256).hexdigest()


def _normalize_sex(raw: str) -> str:
    """Normalise le sexe en 'M' ou 'F'. '?' si valeur inconnue."""
    val = raw.strip().upper()
    if val in ("M", "MASCULIN", "MALE", "1"):
        return "M"
    if val in ("F", "FEMININ", "FÉMININ", "FEMALE", "2"):
        return "F"
    return "?"


def _copy_patients(date_str: str) -> int:
    src = config.SOURCE_DIR / "patients" / date_str / "patients.csv"
    dst = config.LAKE_DIR  / "patients" / date_str / "patients.csv"
    if dst.exists():
        return 0

    dst.parent.mkdir(parents=True, exist_ok=True)
    count = 0

    with open(src, newline="") as fin, open(dst, "w", newline="") as fout:
        reader = csv.DictReader(fin)
        # Colonnes de sortie : PII supprimées, birth_date réduite à birth_year
        writer = csv.DictWriter(
            fout,
            fieldnames=["patient_pseudo", "birth_year", "sex", "region_code"],
        )
        writer.writeheader()
        for row in reader:
            writer.writerow({
                "patient_pseudo": _pseudonymize(row["patient_id"]),
                "birth_year":     int(row["birth_date"][:4]),
                "sex":            _normalize_sex(row["sex"]),
                "region_code":    row["region_code"].strip(),
                # SUPPRIMÉS : patient_id, nom, prenom, nir, birth_date
            })
            count += 1

    return count


def _copy_sejours(date_str: str) -> int:
    src = config.SOURCE_DIR / "sejours" / date_str / "sejours.csv"
    dst = config.LAKE_DIR  / "sejours" / date_str / "sejours.csv"
    if dst.exists():
        return 0

    dst.parent.mkdir(parents=True, exist_ok=True)
    count = 0

    with open(src, newline="") as fin, open(dst, "w", newline="") as fout:
        reader = csv.DictReader(fin)
        # patient_id remplacé par patient_pseudo (même sel que patients)
        # → les jointures entre séjours et patients restent possibles en Silver
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
                "discharge_ts":   row["discharge_ts"],   # vide si séjour en cours
                "admission_mode": row["admission_mode"],
                "discharge_mode": row["discharge_mode"],
            })
            count += 1

    return count


def _copy_diagnostics(date_str: str) -> int:
    src = config.SOURCE_DIR / "diagnostics" / date_str / "diagnostics.json"
    dst = config.LAKE_DIR  / "diagnostics" / date_str / "diagnostics.json"
    if dst.exists():
        return 0

    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, dst)  # aucun PII dans les diagnostics (seulement stay_id)

    with open(dst) as f:
        return len(json.load(f))


def _copy_monitoring(date_str: str) -> int:
    src = config.SOURCE_DIR / "monitoring" / date_str / "monitoring.parquet"
    dst = config.LAKE_DIR  / "monitoring" / date_str / "monitoring.parquet"
    if dst.exists():
        return 0

    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, dst)  # aucun PII (seulement stay_id)

    t = pq.read_table(dst)
    return t.num_rows


def copy_referentiels() -> None:
    """Les référentiels sont déposés une seule fois (J0). Copie idempotente."""
    ref_src = config.SOURCE_DIR / "referentiels"
    ref_dst = config.LAKE_DIR  / "referentiels"
    ref_dst.mkdir(parents=True, exist_ok=True)

    # On prend la date la plus ancienne disponible (référentiels déposés J0)
    date_dirs = sorted(ref_src.iterdir())
    if not date_dirs:
        return

    src_dir = date_dirs[0]
    for f in src_dir.glob("*.csv"):
        dst_file = ref_dst / f.name
        if not dst_file.exists():
            shutil.copy2(f, dst_file)


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
