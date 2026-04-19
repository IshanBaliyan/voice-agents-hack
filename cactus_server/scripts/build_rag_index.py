"""
Offline RAG index builder.

Parses every PDF under cactus_server/docs/ with docling (rendering one PNG
per page + extracting page text), embeds each page with cactus_embed
(reusing the Gemma handle loaded here), and upserts into an embedded Qdrant
collection under cactus_server/qdrant_data/.

Run from the repo root:
    uv run --project cactus_server python -m cactus_server.scripts.build_rag_index

Environment:
    GEMMA4_MODEL_PATH   — absolute path to Gemma 4 weights (required)
    CACTUS_PYTHON_PATH  — path to cactus python checkout (optional)

The resulting directory is self-contained; delete cactus_server/qdrant_data/
to force a full rebuild. Re-running skips PDFs whose (name, size, mtime)
fingerprint already appears in qdrant_data/indexed.json.
"""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import logging
import os
import sys
from pathlib import Path
from typing import Any, Callable, Dict, List

try:
    from dotenv import load_dotenv
    load_dotenv(Path(__file__).resolve().parent.parent / ".env")
except ImportError:
    pass

logging.basicConfig(format="%(asctime)s %(message)s", level=logging.INFO)
logger = logging.getLogger("build_rag_index")


HERE = Path(__file__).resolve().parent
SERVER_DIR = HERE.parent
DEFAULT_DOCS_DIR = SERVER_DIR / "docs"
DEFAULT_QDRANT_DIR = SERVER_DIR / "qdrant_data"
DEFAULT_PAGES_SUBDIR = "pages"
DEFAULT_MANIFEST_NAME = "manifest.yaml"
COLLECTION = "pages"


# ---------------------------------------------------------------------------
# Per-PDF metadata (docs/manifest.yaml) — drives vehicle-aware RAG filtering
# ---------------------------------------------------------------------------

def _load_manifest_metadata(docs_dir: Path) -> Dict[str, Dict[str, Any]]:
    """Return {filename: {make, model, year, display, aliases}} from manifest.yaml.

    Missing manifest is non-fatal — PDFs without metadata are still indexed,
    they just can't be vehicle-filtered.
    """
    manifest_path = docs_dir / DEFAULT_MANIFEST_NAME
    if not manifest_path.exists():
        logger.warning(
            f"No {DEFAULT_MANIFEST_NAME} at {manifest_path} — PDFs will be "
            "indexed without vehicle metadata and cannot be filtered by make/model."
        )
        return {}

    try:
        import yaml  # pulled in transitively by docling
    except ImportError:
        logger.error(
            f"{DEFAULT_MANIFEST_NAME} found but PyYAML is not installed — "
            "install pyyaml or delete the manifest to proceed."
        )
        return {}

    try:
        raw = yaml.safe_load(manifest_path.read_text()) or {}
    except Exception as exc:
        logger.error(f"Failed to parse {manifest_path}: {exc}")
        return {}

    entries = raw.get("entries") or []
    out: Dict[str, Dict[str, Any]] = {}
    for entry in entries:
        fname = entry.get("file")
        if not fname:
            continue
        out[fname] = {
            "make": (entry.get("make") or "").lower() or None,
            "model": (entry.get("model") or "").lower() or None,
            "year": entry.get("year"),
            "display": entry.get("display"),
            "aliases": entry.get("aliases") or [],
        }
    logger.info(f"Loaded vehicle metadata for {len(out)} PDFs from {manifest_path.name}")
    return out


# ---------------------------------------------------------------------------
# Cactus FFI bootstrap (copy of the logic in server.py so the script is
# runnable on its own without importing the FastAPI app).
# ---------------------------------------------------------------------------

def _load_cactus() -> Any:
    default_path = SERVER_DIR / "vendor" / "python"
    cactus_python_path = Path(os.getenv("CACTUS_PYTHON_PATH", default_path))
    module_file = cactus_python_path / "src" / "cactus.py"
    spec = importlib.util.spec_from_file_location("_cactus_ffi", module_file)
    if spec is None or spec.loader is None:
        raise ImportError(f"Cannot locate cactus module at {module_file}")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def _pdf_fingerprint(path: Path) -> str:
    st = path.stat()
    h = hashlib.sha256()
    h.update(path.name.encode())
    h.update(str(st.st_size).encode())
    h.update(str(st.st_mtime_ns).encode())
    return h.hexdigest()[:16]


# ---------------------------------------------------------------------------
# Docling page extraction
# ---------------------------------------------------------------------------

def _parse_pdf_pages(
    pdf_path: Path, pages_out_dir: Path
) -> List[Dict[str, Any]]:
    from docling.datamodel.base_models import InputFormat
    from docling.datamodel.pipeline_options import PdfPipelineOptions
    from docling.document_converter import DocumentConverter, PdfFormatOption

    pipeline_options = PdfPipelineOptions()
    pipeline_options.images_scale = 2.0
    pipeline_options.generate_page_images = True

    converter = DocumentConverter(
        format_options={
            InputFormat.PDF: PdfFormatOption(pipeline_options=pipeline_options)
        }
    )
    result = converter.convert(str(pdf_path))
    doc = result.document

    pages_out_dir.mkdir(parents=True, exist_ok=True)
    stem = pdf_path.stem

    # Group text items by their first provenance page.
    page_chunks: Dict[int, List[str]] = {}
    for item in getattr(doc, "texts", []) or []:
        for prov in getattr(item, "prov", []) or []:
            page_no = getattr(prov, "page_no", None)
            if page_no is None:
                continue
            text = getattr(item, "text", "") or ""
            if text:
                page_chunks.setdefault(page_no, []).append(text)
            break

    pages: List[Dict[str, Any]] = []
    for page_no, page in doc.pages.items():
        img_path = pages_out_dir / f"{stem}__p{page_no:04d}.png"
        pil_image = None
        if getattr(page, "image", None) is not None:
            pil_image = getattr(page.image, "pil_image", None)
        if pil_image is not None:
            pil_image.save(img_path)
        text = "\n".join(page_chunks.get(page_no, [])).strip()
        pages.append(
            {
                "page_no": page_no,
                "text": text,
                "image_path": str(img_path.resolve()),
            }
        )
    return pages


# ---------------------------------------------------------------------------
# Qdrant helpers
# ---------------------------------------------------------------------------

def _ensure_collection(client, collection: str, dim: int) -> None:
    from qdrant_client.models import Distance, VectorParams

    existing = {c.name for c in client.get_collections().collections}
    if collection not in existing:
        client.create_collection(
            collection_name=collection,
            vectors_config=VectorParams(size=dim, distance=Distance.COSINE),
        )
        logger.info(f"Created Qdrant collection {collection!r} (dim={dim})")


def _load_manifest(qdrant_dir: Path) -> Dict[str, str]:
    manifest_path = qdrant_dir / "indexed.json"
    if manifest_path.exists():
        try:
            return json.loads(manifest_path.read_text())
        except Exception:
            return {}
    return {}


def _save_manifest(qdrant_dir: Path, manifest: Dict[str, str]) -> None:
    qdrant_dir.mkdir(parents=True, exist_ok=True)
    (qdrant_dir / "indexed.json").write_text(json.dumps(manifest, indent=2))


def _point_id(doc_hash: str, page_no: int) -> int:
    digest = hashlib.sha256(f"{doc_hash}:{page_no}".encode()).hexdigest()
    return int(digest[:15], 16)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def build(
    docs_dir: Path,
    qdrant_dir: Path,
    embed_fn: Callable[[str], List[float]],
    force: bool = False,
) -> int:
    from qdrant_client import QdrantClient
    from qdrant_client.models import PointStruct

    pdfs = sorted(docs_dir.glob("*.pdf"))
    if not pdfs:
        logger.warning(f"No PDFs found in {docs_dir}")
        return 0

    vehicle_meta = _load_manifest_metadata(docs_dir)

    pages_out_dir = qdrant_dir / DEFAULT_PAGES_SUBDIR
    qdrant_dir.mkdir(parents=True, exist_ok=True)
    client = QdrantClient(path=str(qdrant_dir))

    manifest = {} if force else _load_manifest(qdrant_dir)
    dim: int | None = None
    if COLLECTION in {c.name for c in client.get_collections().collections}:
        dim = client.get_collection(COLLECTION).config.params.vectors.size

    total_added = 0

    for pdf in pdfs:
        fingerprint = _pdf_fingerprint(pdf)
        if not force and manifest.get(pdf.name) == fingerprint:
            logger.info(f"skip {pdf.name} (already indexed @ {fingerprint})")
            continue

        logger.info(f"docling: parsing {pdf.name}…")
        try:
            pages = _parse_pdf_pages(pdf, pages_out_dir)
        except Exception as exc:
            logger.error(f"docling failed on {pdf.name}: {exc}", exc_info=True)
            continue

        points: List[Any] = []
        for page in pages:
            text = page["text"]
            if not text:
                continue
            vec = embed_fn(text)
            if dim is None:
                dim = len(vec)
                _ensure_collection(client, COLLECTION, dim)
            elif len(vec) != dim:
                raise RuntimeError(
                    f"Embedding dim mismatch: got {len(vec)}, expected {dim}"
                )
            meta = vehicle_meta.get(pdf.name, {})
            payload: Dict[str, Any] = {
                "source": pdf.name,
                "page": page["page_no"],
                "image_path": page["image_path"],
                "doc_hash": fingerprint,
                "text_preview": text[:240],
            }
            if meta.get("make"):
                payload["make"] = meta["make"]
            if meta.get("model"):
                payload["model"] = meta["model"]
            if meta.get("year") is not None:
                payload["year"] = int(meta["year"])
            if meta.get("display"):
                payload["display"] = meta["display"]
            points.append(
                PointStruct(
                    id=_point_id(fingerprint, page["page_no"]),
                    vector=vec,
                    payload=payload,
                )
            )

        if points:
            client.upsert(collection_name=COLLECTION, points=points)
            total_added += len(points)
            logger.info(f"  → indexed {len(points)} pages from {pdf.name}")

        manifest[pdf.name] = fingerprint
        _save_manifest(qdrant_dir, manifest)

    client.close()
    return total_added


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--docs-dir", type=Path, default=DEFAULT_DOCS_DIR)
    parser.add_argument("--qdrant-dir", type=Path, default=DEFAULT_QDRANT_DIR)
    parser.add_argument(
        "--force",
        action="store_true",
        help="Re-parse and re-embed every PDF even if already indexed",
    )
    args = parser.parse_args()

    gemma_path = os.getenv("GEMMA4_MODEL_PATH", "")
    if not gemma_path:
        logger.error(
            "GEMMA4_MODEL_PATH not set — export it or put it in cactus_server/.env"
        )
        return 1

    cactus = _load_cactus()

    logger.info(f"Loading Gemma 4 from {gemma_path} (for embeddings)…")
    handle = cactus.cactus_init(gemma_path, None, False)
    logger.info("Gemma 4 loaded")

    def embed(text: str) -> List[float]:
        return cactus.cactus_embed(handle, text, True)

    try:
        added = build(
            docs_dir=args.docs_dir,
            qdrant_dir=args.qdrant_dir,
            embed_fn=embed,
            force=args.force,
        )
    finally:
        try:
            cactus.cactus_destroy(handle)
        except Exception:
            pass

    logger.info(f"Done. Added {added} page vectors.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
