"""
Vehicle catalog + utterance parsing.

Loads docs/manifest.yaml and provides two things:

1. A normalization helper — so "2018 Toyota Camry", "Camry", "camry 2018" all
   collapse onto the same {make, model, year} triple that matches what the
   build_rag_index.py script stored in Qdrant.

2. A detector that scans a free-form utterance and extracts the most
   confident vehicle mention. Used by the WebSocket session so the user can
   say "I have a 2018 Toyota Camry, how do I change the oil?" and have the
   RAG filter auto-update, even without the iOS app sending an explicit
   vehicle context message.

Design notes:
- Substring matching on a normalized string (lowercase, dashes/spaces collapsed
  into nothing) catches "cr-v" == "crv", "F-150" == "f150", etc.
- Make is matched first; if a make is present, we only look for models
  within that make's catalog so "1500" doesn't indiscriminately match all
  three of Silverado/Sierra/RAM. If no make is detected, a model match
  still wins as long as it's unambiguous.
- Years are extracted by regex and sanity-checked (1990..2030).
"""

from __future__ import annotations

import logging
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, List, Optional

logger = logging.getLogger(__name__)


_YEAR_RE = re.compile(r"\b(19[9]\d|20[0-3]\d)\b")


def _normalize(text: str) -> str:
    """Lowercase + strip all whitespace/dashes so 'F-150' == 'f150'."""
    return re.sub(r"[\s\-_]+", "", (text or "").lower())


@dataclass
class VehicleEntry:
    file: str
    make: str
    model: str
    year: Optional[int]
    display: str
    aliases: List[str] = field(default_factory=list)


@dataclass
class VehicleMatch:
    make: Optional[str] = None
    model: Optional[str] = None
    year: Optional[int] = None
    display: Optional[str] = None

    @property
    def is_empty(self) -> bool:
        return self.make is None and self.model is None and self.year is None


@dataclass
class VehicleCatalog:
    entries: List[VehicleEntry]

    # derived lookup tables
    _makes: Dict[str, str] = field(default_factory=dict)
    _models_by_make: Dict[str, Dict[str, str]] = field(default_factory=dict)
    _all_models: Dict[str, List[str]] = field(default_factory=dict)

    def __post_init__(self) -> None:
        for e in self.entries:
            norm_make = _normalize(e.make)
            self._makes[norm_make] = e.make
            for alias in [e.make, *e.aliases]:
                self._makes.setdefault(_normalize(alias), e.make)

            norm_model = _normalize(e.model)
            self._models_by_make.setdefault(e.make, {})[norm_model] = e.model
            for alias in [e.model, *e.aliases]:
                self._models_by_make[e.make].setdefault(_normalize(alias), e.model)

            self._all_models.setdefault(norm_model, []).append(e.make)

    def detect(self, text: str) -> VehicleMatch:
        """Extract a vehicle mention from free-form text. Never raises."""
        if not text:
            return VehicleMatch()

        norm = _normalize(text)
        match = VehicleMatch()

        year_m = _YEAR_RE.search(text)
        if year_m:
            match.year = int(year_m.group(0))

        found_make: Optional[str] = None
        for norm_make, canonical in sorted(self._makes.items(), key=lambda x: -len(x[0])):
            if norm_make and norm_make in norm:
                found_make = canonical
                match.make = canonical
                break

        if found_make:
            for norm_model, canonical in sorted(
                self._models_by_make[found_make].items(), key=lambda x: -len(x[0])
            ):
                if norm_model and norm_model in norm:
                    match.model = canonical
                    break
        else:
            for norm_model, makes in sorted(self._all_models.items(), key=lambda x: -len(x[0])):
                if norm_model and norm_model in norm and len(set(makes)) == 1:
                    match.model = norm_model
                    match.make = makes[0]
                    break

        if match.make and match.model:
            for e in self.entries:
                if e.make == match.make and e.model == match.model:
                    match.display = e.display
                    # Don't backfill year — caller decides whether to pass
                    # year to the RAG filter (usually we DON'T, because the
                    # user's year may not match what's in the index and a
                    # same-model adjacent-year manual is still useful).
                    break
        return match


def load_catalog(docs_dir: Path) -> Optional[VehicleCatalog]:
    manifest_path = docs_dir / "manifest.yaml"
    if not manifest_path.exists():
        logger.info(f"vehicle: no manifest at {manifest_path} — detection disabled")
        return None
    try:
        import yaml
    except ImportError:
        logger.warning("vehicle: PyYAML not installed — catalog disabled")
        return None
    try:
        raw = yaml.safe_load(manifest_path.read_text()) or {}
    except Exception as exc:
        logger.warning(f"vehicle: failed to parse {manifest_path}: {exc}")
        return None

    entries: List[VehicleEntry] = []
    for item in raw.get("entries") or []:
        file = item.get("file")
        make = (item.get("make") or "").lower()
        model = (item.get("model") or "").lower()
        if not (file and make and model):
            continue
        entries.append(
            VehicleEntry(
                file=file,
                make=make,
                model=model,
                year=item.get("year"),
                display=item.get("display") or f"{make} {model}",
                aliases=[str(a).lower() for a in (item.get("aliases") or [])],
            )
        )
    if not entries:
        logger.warning(f"vehicle: manifest {manifest_path} has no usable entries")
        return None
    logger.info(f"vehicle: loaded catalog with {len(entries)} entries")
    return VehicleCatalog(entries=entries)
