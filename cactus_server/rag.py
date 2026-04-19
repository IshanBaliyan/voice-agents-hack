"""
Qdrant-backed RAG for the Cactus model server.

Thin wrapper around qdrant-client + fastembed so the server can retrieve
document chunks and inject them into Gemma's system prompt.

Modes
-----
- Local embedded (default): Qdrant stores data in a local directory, no
  separate server process required. Single-process lock — stop the model
  server before running ingest.
- Remote: set CACTUS_RAG_URL=http://host:6333 to hit a Qdrant server
  (e.g. one running in Docker).

Environment variables
---------------------
  CACTUS_RAG_ENABLED      "1" to enable (default), "0" to skip at startup
  CACTUS_RAG_URL          http(s)://host:6333 — use remote Qdrant
  CACTUS_RAG_STORAGE      local Qdrant storage directory
                          (default: <cactus_server>/qdrant_data)
  CACTUS_RAG_COLLECTION   collection name (default: cactus_rag)
  CACTUS_RAG_TOP_K        results per search (default: 4)
  CACTUS_RAG_EMBED_MODEL  fastembed model name
                          (default: BAAI/bge-small-en-v1.5, 384-dim)
"""

from __future__ import annotations

import logging
import os
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, List, Optional, Sequence

logger = logging.getLogger(__name__)

_DEFAULT_STORAGE = str(Path(__file__).resolve().parent / "qdrant_data")
_DEFAULT_COLLECTION = "cactus_rag"
_DEFAULT_TOP_K = 4
_DEFAULT_EMBED_MODEL = "BAAI/bge-small-en-v1.5"


@dataclass
class RAGHit:
    text: str
    score: float
    source: str
    page: Optional[int] = None


class QdrantRAG:
    """
    Qdrant + fastembed wrapper. All heavyweight imports are deferred to
    __init__ so importing this module costs nothing when RAG is disabled.
    """

    def __init__(
        self,
        collection: Optional[str] = None,
        storage: Optional[str] = None,
        url: Optional[str] = None,
        embed_model: Optional[str] = None,
        top_k: Optional[int] = None,
    ) -> None:
        from qdrant_client import QdrantClient
        from fastembed import TextEmbedding

        self.collection = collection or os.getenv(
            "CACTUS_RAG_COLLECTION", _DEFAULT_COLLECTION
        )
        self.storage = storage or os.getenv("CACTUS_RAG_STORAGE", _DEFAULT_STORAGE)
        self.url = url if url is not None else os.getenv("CACTUS_RAG_URL", "")
        self.embed_model_name = embed_model or os.getenv(
            "CACTUS_RAG_EMBED_MODEL", _DEFAULT_EMBED_MODEL
        )
        self.top_k = int(top_k or os.getenv("CACTUS_RAG_TOP_K", _DEFAULT_TOP_K))

        if self.url:
            self._client = QdrantClient(url=self.url)
            logger.info(f"RAG: using remote Qdrant at {self.url}")
        else:
            Path(self.storage).mkdir(parents=True, exist_ok=True)
            self._client = QdrantClient(path=self.storage)
            logger.info(f"RAG: using local Qdrant at {self.storage}")

        self._embedder = TextEmbedding(model_name=self.embed_model_name)
        probe = next(iter(self._embedder.embed(["probe"])))
        self._vector_size = len(probe)
        logger.info(
            f"RAG: embed model={self.embed_model_name} dim={self._vector_size}"
        )

    # --- Collection management --------------------------------------------

    def ensure_collection(self) -> None:
        from qdrant_client.models import Distance, VectorParams

        exists = False
        try:
            exists = self._client.collection_exists(self.collection)
        except Exception:
            pass

        if exists:
            try:
                info = self._client.get_collection(self.collection)
                params = info.config.params.vectors
                existing_size = getattr(params, "size", None)
                if existing_size and existing_size != self._vector_size:
                    raise RuntimeError(
                        f"Collection '{self.collection}' was created with "
                        f"dim={existing_size}, but the current embedder produces "
                        f"dim={self._vector_size}. Run `make ingest-reset` "
                        f"to drop and re-create."
                    )
            except RuntimeError:
                raise
            except Exception:
                pass
            return

        self._client.create_collection(
            collection_name=self.collection,
            vectors_config=VectorParams(
                size=self._vector_size,
                distance=Distance.COSINE,
            ),
        )
        logger.info(
            f"RAG: created collection {self.collection} (dim={self._vector_size})"
        )

    def drop_collection(self) -> None:
        try:
            self._client.delete_collection(self.collection)
            logger.info(f"RAG: dropped collection {self.collection}")
        except Exception as exc:
            logger.warning(f"RAG: drop_collection failed: {exc}")

    def count(self) -> int:
        try:
            return int(self._client.count(collection_name=self.collection).count)
        except Exception:
            return 0

    # --- Embedding + search -----------------------------------------------

    def _to_list(self, v: Any) -> List[float]:
        return v.tolist() if hasattr(v, "tolist") else list(v)

    def _embed_one(self, text: str) -> List[float]:
        return self._to_list(next(iter(self._embedder.embed([text]))))

    def _embed_many(self, texts: Sequence[str]) -> List[List[float]]:
        return [self._to_list(v) for v in self._embedder.embed(list(texts))]

    def search(self, query: str, top_k: Optional[int] = None) -> List[RAGHit]:
        q = (query or "").strip()
        if not q:
            return []
        k = top_k or self.top_k
        try:
            vec = self._embed_one(q)
        except Exception as exc:
            logger.warning(f"RAG: embed failed: {exc}")
            return []

        try:
            res = self._client.query_points(
                collection_name=self.collection,
                query=vec,
                limit=k,
                with_payload=True,
            )
            points = res.points
        except Exception as exc:
            logger.warning(f"RAG: query failed: {exc}")
            return []

        hits: List[RAGHit] = []
        for p in points:
            payload = p.payload or {}
            hits.append(
                RAGHit(
                    text=str(payload.get("text", "")),
                    score=float(p.score or 0.0),
                    source=str(payload.get("source", "")),
                    page=payload.get("page"),
                )
            )
        return hits

    # --- Ingest ------------------------------------------------------------

    def upsert(
        self,
        ids: Sequence[int],
        texts: Sequence[str],
        metadatas: Sequence[Dict[str, Any]],
    ) -> None:
        from qdrant_client.models import PointStruct

        vectors = self._embed_many(texts)
        points = [
            PointStruct(id=int(i), vector=v, payload={"text": t, **m})
            for i, v, t, m in zip(ids, vectors, texts, metadatas)
        ]
        self._client.upsert(collection_name=self.collection, points=points)

    # --- Lifecycle ---------------------------------------------------------

    def close(self) -> None:
        try:
            self._client.close()
        except Exception:
            pass


def format_context(hits: Sequence[RAGHit], max_chars: int = 2400) -> str:
    """Format RAG hits for injection into a Gemma system prompt."""
    if not hits:
        return ""
    out: List[str] = []
    total = 0
    for i, h in enumerate(hits, start=1):
        loc = h.source or "source"
        if h.page:
            loc = f"{loc} p.{h.page}"
        entry = f"[{i}] ({loc}) {h.text}"
        if total + len(entry) > max_chars:
            remaining = max_chars - total
            if remaining > 32:
                out.append(entry[:remaining].rstrip() + "…")
            break
        out.append(entry)
        total += len(entry) + 1
    return "\n".join(out)
