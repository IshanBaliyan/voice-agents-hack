"""
Runtime RAG index wrapper for cactus_server.

The Qdrant collection is built offline by scripts/build_rag_index.py — this
module only opens the existing on-disk database and serves searches. If the
collection is missing, open() returns None so the server can log a warning
and keep running without RAG.

Page images (PNG) rendered by docling live alongside the Qdrant data under
cactus_server/qdrant_data/pages/; each Qdrant point's payload stores the
absolute path so the server can base64-encode it into a page_image frame.
"""

from __future__ import annotations

import logging
from pathlib import Path
from typing import Any, Dict, List, Optional

logger = logging.getLogger(__name__)

DEFAULT_COLLECTION = "pages"


class RagIndex:
    def __init__(self, client, collection: str, dim: int) -> None:
        self._client = client
        self._collection = collection
        self._dim = dim

    @property
    def dim(self) -> int:
        return self._dim

    def search(
        self,
        query_vec: List[float],
        top_k: int = 1,
        make: Optional[str] = None,
        model: Optional[str] = None,
        year: Optional[int] = None,
    ) -> List[Dict[str, Any]]:
        """Semantic search, optionally narrowed to a specific vehicle.

        When a vehicle filter is supplied, Qdrant pre-filters by payload
        (make/model/year) before scoring — so retrieval only touches pages
        from the matching PDF(s). If no pages have the requested metadata,
        the filter returns zero hits (the server logs this and the user
        sees no page_image frame, which is the right behavior — we don't
        want cross-vehicle bleed-through just because nothing matched).
        """
        query_filter = _build_filter(make=make, model=model, year=year)
        hits = self._client.query_points(
            collection_name=self._collection,
            query=query_vec,
            limit=top_k,
            query_filter=query_filter,
        ).points
        return [
            {
                "source": h.payload.get("source"),
                "page": h.payload.get("page"),
                "image_path": h.payload.get("image_path"),
                "text_preview": h.payload.get("text_preview"),
                "make": h.payload.get("make"),
                "model": h.payload.get("model"),
                "year": h.payload.get("year"),
                "display": h.payload.get("display"),
                "score": float(h.score),
            }
            for h in hits
        ]


def _build_filter(
    make: Optional[str] = None,
    model: Optional[str] = None,
    year: Optional[int] = None,
):
    if not any([make, model, year]):
        return None
    from qdrant_client.models import FieldCondition, Filter, MatchValue

    must = []
    if make:
        must.append(FieldCondition(key="make", match=MatchValue(value=make.lower())))
    if model:
        must.append(FieldCondition(key="model", match=MatchValue(value=model.lower())))
    if year is not None:
        must.append(FieldCondition(key="year", match=MatchValue(value=int(year))))
    return Filter(must=must)


def open_index(
    qdrant_path: Path, collection: str = DEFAULT_COLLECTION
) -> Optional[RagIndex]:
    """Open a previously-built Qdrant collection. Returns None if missing."""
    if not qdrant_path.exists():
        logger.warning(
            f"RAG: qdrant directory {qdrant_path} does not exist — "
            "run scripts/build_rag_index.py to create it."
        )
        return None

    try:
        from qdrant_client import QdrantClient
    except ImportError as exc:
        logger.warning(f"RAG: qdrant-client not installed ({exc})")
        return None

    try:
        client = QdrantClient(path=str(qdrant_path))
        collections = {c.name for c in client.get_collections().collections}
    except Exception as exc:
        logger.warning(f"RAG: failed to open Qdrant at {qdrant_path}: {exc}")
        return None

    if collection not in collections:
        logger.warning(
            f"RAG: collection {collection!r} not found at {qdrant_path} — "
            "run scripts/build_rag_index.py first."
        )
        return None

    info = client.get_collection(collection)
    dim = info.config.params.vectors.size
    logger.info(
        f"RAG: opened collection {collection!r} (dim={dim}, "
        f"points={info.points_count}) from {qdrant_path}"
    )
    return RagIndex(client=client, collection=collection, dim=dim)
