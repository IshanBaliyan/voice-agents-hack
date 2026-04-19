"""
Download Gemma 4 E4B (Cactus-compiled) weights from Hugging Face and
extract the Apple Silicon int4 bundle into ./models/gemma-4-E4B-it/ so the
model server can load it directly.

Run via `make download-model` (preferred) or:
    uv run --with huggingface_hub python scripts/download_model.py
"""

import os
import platform
import shutil
import sys
import zipfile
from pathlib import Path

from huggingface_hub import snapshot_download

REPO_ID = "Cactus-Compute/gemma-4-E4B-it"

HERE = Path(__file__).resolve().parent.parent
MODELS_DIR = HERE / "models"
DEST_DIR = MODELS_DIR / "gemma-4-E4B-it"


def _pick_zip(snapshot_dir: Path) -> Path:
    weights = snapshot_dir / "weights"
    if platform.system() == "Darwin" and platform.machine() == "arm64":
        candidate = weights / "gemma-4-e4b-it-int4-apple.zip"
    else:
        candidate = weights / "gemma-4-e4b-it-int4.zip"
    if not candidate.exists():
        raise SystemExit(f"Expected weights zip not found: {candidate}")
    return candidate


def main() -> None:
    MODELS_DIR.mkdir(parents=True, exist_ok=True)

    if DEST_DIR.exists() and any(DEST_DIR.iterdir()):
        print(f"[download_model] {DEST_DIR} already populated — skipping.")
        print(f"[download_model] Delete it and re-run to force re-download.")
        _print_export(DEST_DIR)
        return

    print(f"[download_model] Downloading {REPO_ID} from Hugging Face…")
    snapshot = Path(
        snapshot_download(
            repo_id=REPO_ID,
            cache_dir=str(MODELS_DIR / ".hf_cache"),
        )
    )
    zip_path = _pick_zip(snapshot)
    print(f"[download_model] Extracting {zip_path.name} → {DEST_DIR}")

    DEST_DIR.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(zip_path) as zf:
        zf.extractall(DEST_DIR)

    # Copy config.json alongside the weights so Cactus has the full bundle.
    config_src = snapshot / "config.json"
    if config_src.exists():
        shutil.copy2(config_src, DEST_DIR / "config.json")

    print(f"[download_model] Done. Weights at: {DEST_DIR}")
    _print_export(DEST_DIR)


def _print_export(path: Path) -> None:
    print()
    print("Add this to your shell or to cactus_server/.env:")
    print(f"  GEMMA4_MODEL_PATH={path}")


if __name__ == "__main__":
    sys.exit(main())
