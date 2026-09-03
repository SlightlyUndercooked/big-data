"""
ÉTAPE 0 — LAKE ET PSEUDONYMISATION

Patients / séjours : patient_id → HMAC-SHA256 (sel PIPELINE_SALT),
PII retirées, birth_date → birth_year, sexe normalisé.

HMAC plutôt que SHA256 seul : sans sel, un dictionnaire d'IPP
retrouverait tous les pseudos.

Diagnostics, monitoring, référentiels : copie brute (pas de PII).

Idempotent : fichier lake déjà présent → skip.
Écriture .tmp puis os.replace : un crash ne laisse pas un fichier
tronqué pris pour « déjà fait ».
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
    return dst.with_name(dst.name + ".tmp")


def _atomic_copy(src: Path, dst: Path) -> None:
    """Copie src → dst de manière atomique via .tmp + os.replace."""
    tmp = _tmp_path(dst)
    shutil.copy2(src, tmp)
    os.replace(tmp, dst)


def _pseudonymize(patient_id: str) -> str:
    """HMAC déterministe : même patient_id → même pseudo (jointures sans IPP)."""
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

    if not src.exists():
        return 0

    if dst.exists():
        return 0

    dst.parent.mkdir(parents=True, exist_ok=True)
    tmp = _tmp_path(dst)
    count = 0

    with open(src, newline="") as fin, open(tmp, "w", newline="") as fout:
        reader = csv.DictReader(fin)
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
            })
            count += 1

    os.replace(tmp, dst)
    return count


def _copy_sejours(date_str: str) -> int:
    src = config.SOURCE_DIR / "sejours" / date_str / "sejours.csv"
    dst = config.LAKE_DIR  / "sejours" / date_str / "sejours.csv"
    if not src.exists() or dst.exists():
        return 0

    dst.parent.mkdir(parents=True, exist_ok=True)
    tmp = _tmp_path(dst)
    count = 0

    with open(src, newline="") as fin, open(tmp, "w", newline="") as fout:
        reader = csv.DictReader(fin)
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
                "discharge_ts":   row["discharge_ts"],
                "admission_mode": row["admission_mode"],
                "discharge_mode": row["discharge_mode"],
            })
            count += 1

    os.replace(tmp, dst)
    return count


def _copy_diagnostics(date_str: str) -> int:
    src = config.SOURCE_DIR / "diagnostics" / date_str / "diagnostics.json"
    dst = config.LAKE_DIR  / "diagnostics" / date_str / "diagnostics.json"
    if not src.exists() or dst.exists():
        return 0

    dst.parent.mkdir(parents=True, exist_ok=True)
    _atomic_copy(src, dst)

    with open(dst) as f:
        return len(json.load(f))


def _copy_monitoring(date_str: str) -> int:
    src = config.SOURCE_DIR / "monitoring" / date_str / "monitoring.parquet"
    dst = config.LAKE_DIR  / "monitoring" / date_str / "monitoring.parquet"
    if not src.exists() or dst.exists():
        return 0

    dst.parent.mkdir(parents=True, exist_ok=True)
    _atomic_copy(src, dst)

    t = pq.read_table(dst)
    return t.num_rows


def _copy_actes(date_str: str) -> int:
    src = config.SOURCE_DIR / "actes" / date_str / "actes.parquet"
    dst = config.LAKE_DIR  / "actes" / date_str / "actes.parquet"
    if not src.exists() or dst.exists():
        return 0

    dst.parent.mkdir(parents=True, exist_ok=True)
    # Copie brute : pas de PII (stay_id + code d'acte + horodatage).
    _atomic_copy(src, dst)

    t = pq.read_table(dst)
    return t.num_rows


def copy_referentiels() -> None:
    """Copie tous les référentiels vers le lake, à plat.

    Le CHU ne dépose plus seulement à J0 : le lot 2026-08-29 ajoute
    description_service.csv et ccam.csv. On parcourt donc TOUS les dossiers
    de dates, du plus ancien au plus récent, et non le seul premier.

    Écrasement systématique (plus de garde `if not dst.exists()`) : un
    dépôt récent doit pouvoir corriger un fichier de même nom déposé plus
    tôt. Le tri chronologique donne la sémantique « le dernier dépôt gagne ».
    La copie reste atomique, donc un fichier n'est jamais vu à moitié écrit.
    """
    ref_src = config.SOURCE_DIR / "referentiels"
    ref_dst = config.LAKE_DIR  / "referentiels"
    ref_dst.mkdir(parents=True, exist_ok=True)

    if not ref_src.exists():
        return

    for src_dir in sorted(p for p in ref_src.iterdir() if p.is_dir()):
        for f in src_dir.glob("*.csv"):
            _atomic_copy(f, ref_dst / f.name)


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
        "actes":       _copy_actes(date_str),
    }
