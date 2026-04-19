"""
Kokoro TTS wrapper.

Synthesises English text to 24 kHz PCM16-LE bytes (Kokoro's native rate)
so the iOS client can play each chunk via AVAudioPlayerNode.scheduleBuffer
with zero server-side resampling. The iOS AudioManager's playerFormat is
pinned to 24 kHz mono Int16 to match.

Two backends are supported, picked in this order:
  1. kokoro-onnx (preferred) — ONNX Runtime, ~2–3× faster on CPU than the
     reference PyTorch pipeline and works everywhere without GPU quirks.
     Requires the ONNX model + voices bundle (see KOKORO_ONNX_MODEL /
     KOKORO_ONNX_VOICES env vars).
  2. kokoro (PyTorch reference) — fallback used only if the ONNX model
     files aren't found or the package isn't installed.

Loaded lazily on the first call; callers should invoke warmup() at
process startup to pay the model-init cost once, not on the first user
turn. If neither backend is available, synthesize_pcm16() returns None
and callers can fall back to a different TTS.
"""

from __future__ import annotations

import logging
import os
import threading
import time
from typing import Optional

import numpy as np

logger = logging.getLogger(__name__)

_KOKORO_SAMPLE_RATE = 24_000
_TARGET_SAMPLE_RATE = 24_000
_DEFAULT_VOICE = "af_heart"

_pipeline = None          # kokoro.KPipeline instance (torch fallback)
_onnx_pipeline = None     # kokoro_onnx.Kokoro instance (preferred)
_pipeline_lock = threading.Lock()
_pipeline_failed = False
_backend: str = "none"    # one of: "onnx", "torch", "none"
_pipeline_device: str = "cpu"

_DEFAULT_ONNX_MODEL = os.path.join(
    os.path.dirname(os.path.abspath(__file__)),
    "models", "kokoro", "kokoro-v1.0.onnx",
)
_DEFAULT_ONNX_VOICES = os.path.join(
    os.path.dirname(os.path.abspath(__file__)),
    "models", "kokoro", "voices-v1.0.bin",
)


def _pick_device() -> str:
    """Return the torch device used by the torch fallback pipeline.

    CUDA is used when available. MPS is **opt-in** via
    ``KOKORO_DEVICE=mps`` because Kokoro's istftnet vocoder uses
    ``torch.stft`` / ``torch.istft`` ops that silently fall back to CPU
    under MPS — the round-trip tensor copies make inference ~3–4×
    slower than plain CPU on Apple Silicon.
    """
    override = os.environ.get("KOKORO_DEVICE", "").strip().lower()
    if override in {"cpu", "cuda", "mps"}:
        return override
    try:
        import torch  # type: ignore
    except Exception:
        return "cpu"
    if torch.cuda.is_available():
        return "cuda"
    return "cpu"


def _try_init_onnx() -> bool:
    """Attempt to construct the kokoro-onnx pipeline. Returns True on
    success. Sets module globals on success; leaves them untouched on
    failure so the caller can fall back."""
    global _onnx_pipeline, _backend
    try:
        from kokoro_onnx import Kokoro  # type: ignore
    except ImportError as exc:
        logger.info(f"kokoro-onnx not installed ({exc}); using torch backend.")
        return False

    model_path = os.environ.get("KOKORO_ONNX_MODEL", _DEFAULT_ONNX_MODEL)
    voices_path = os.environ.get("KOKORO_ONNX_VOICES", _DEFAULT_ONNX_VOICES)
    if not (os.path.exists(model_path) and os.path.exists(voices_path)):
        logger.warning(
            f"kokoro-onnx model files not found at {model_path} / {voices_path}; "
            f"using torch backend."
        )
        return False

    try:
        logger.info(f"Initialising kokoro-onnx (model={model_path})…")
        _onnx_pipeline = Kokoro(model_path, voices_path)
        _backend = "onnx"
        logger.info("kokoro-onnx ready.")
        return True
    except Exception as exc:
        logger.warning(f"kokoro-onnx init failed: {exc}; using torch backend.")
        _onnx_pipeline = None
        return False


def _try_init_torch() -> bool:
    """Attempt to construct the torch kokoro pipeline. Returns True on success."""
    global _pipeline, _pipeline_device, _backend
    try:
        from kokoro import KPipeline  # type: ignore
    except ImportError as exc:
        logger.error(f"Neither kokoro-onnx nor kokoro available: {exc}")
        return False

    _pipeline_device = _pick_device()
    logger.info(
        f"Initialising kokoro (torch) pipeline (lang_code='a', device='{_pipeline_device}')…"
    )
    try:
        try:
            _pipeline = KPipeline(lang_code="a", device=_pipeline_device)
        except TypeError:
            _pipeline = KPipeline(lang_code="a")
            model = getattr(_pipeline, "model", None)
            if model is not None and hasattr(model, "to"):
                try:
                    model.to(_pipeline_device)
                except Exception as move_exc:
                    logger.warning(
                        f"Could not move Kokoro model to {_pipeline_device}: {move_exc}"
                    )
                    _pipeline_device = "cpu"
        _backend = "torch"
        logger.info(f"kokoro (torch) ready on '{_pipeline_device}'.")
        return True
    except Exception as exc:
        logger.error(f"Failed to init kokoro (torch): {exc}")
        return False


def _ensure_initialised() -> bool:
    """Lazy-init the preferred backend. Returns True if some backend is ready."""
    global _pipeline_failed
    if _backend != "none":
        return True
    if _pipeline_failed:
        return False
    with _pipeline_lock:
        if _backend != "none":
            return True
        if _pipeline_failed:
            return False
        if _try_init_onnx():
            return True
        if _try_init_torch():
            return True
        _pipeline_failed = True
        return False


def _run_onnx(text: str, voice: str) -> Optional[np.ndarray]:
    """Synth via kokoro-onnx → float32 waveform at _KOKORO_SAMPLE_RATE."""
    assert _onnx_pipeline is not None
    samples, sample_rate = _onnx_pipeline.create(
        text, voice=voice, speed=1.2, lang="en-us",
    )
    if sample_rate != _KOKORO_SAMPLE_RATE:
        logger.warning(
            f"kokoro-onnx returned {sample_rate} Hz, expected {_KOKORO_SAMPLE_RATE}; "
            "client playback will be pitch-shifted."
        )
    return np.asarray(samples, dtype=np.float32).reshape(-1)


def _run_torch(text: str, voice: str) -> Optional[np.ndarray]:
    """Synth via torch kokoro → float32 waveform at _KOKORO_SAMPLE_RATE."""
    assert _pipeline is not None
    chunks: list[np.ndarray] = []
    for _, _, audio in _pipeline(text, voice=voice, speed=1.2):
        arr = audio.detach().cpu().numpy() if hasattr(audio, "detach") else np.asarray(audio)
        chunks.append(arr.astype(np.float32, copy=False).reshape(-1))
    if not chunks:
        return None
    return np.concatenate(chunks) if len(chunks) > 1 else chunks[0]


def synthesize_pcm16(text: str, voice: str = _DEFAULT_VOICE) -> Optional[bytes]:
    """
    Return raw PCM16-LE @ 24 kHz mono for *text*, or None on failure.
    Suitable for direct injection into the iOS AudioManager.playPCM16 path.

    Logs per-stage latency (model inference, quantise) at INFO so we can
    spot regressions without re-running with DEBUG on.
    """
    text = (text or "").strip()
    if not text:
        return None

    if not _ensure_initialised():
        return None

    try:
        t_start = time.monotonic()
        if _backend == "onnx":
            waveform = _run_onnx(text, voice)
        elif _backend == "torch":
            waveform = _run_torch(text, voice)
        else:
            return None
        t_infer = time.monotonic()
        if waveform is None or waveform.size == 0:
            return None
        # Kokoro is 24 kHz native and the iOS client plays at 24 kHz — no
        # resample, straight float32 → int16.
        np.clip(waveform, -1.0, 1.0, out=waveform)
        pcm = (waveform * 32767.0).astype(np.int16, copy=False)
        t_quant = time.monotonic()
        n_samples = pcm.shape[0]
        audio_ms = 1000.0 * n_samples / _KOKORO_SAMPLE_RATE
        infer_ms = (t_infer - t_start) * 1000
        quant_ms = (t_quant - t_infer) * 1000
        total_ms = (t_quant - t_start) * 1000
        rtf = total_ms / audio_ms if audio_ms > 0 else float("inf")
        logger.info(
            f"Kokoro[{_backend}] synth: infer={infer_ms:.0f}ms "
            f"quant={quant_ms:.1f}ms total={total_ms:.0f}ms "
            f"audio={audio_ms:.0f}ms rtf={rtf:.2f} chars={len(text)}"
        )
        return pcm.tobytes()
    except Exception as exc:
        logger.error(f"Kokoro synthesis failed for text {text!r}: {exc}")
        return None


def warmup() -> None:
    """
    Force pipeline init + run one short synth so the first user-facing
    sentence doesn't pay the cold-start cost. Safe to call from any thread;
    silent no-op if Kokoro is unavailable.
    """
    t0 = time.monotonic()
    if not _ensure_initialised():
        return
    try:
        _ = synthesize_pcm16("Ready.")
        logger.info(
            f"Kokoro warmup complete in {(time.monotonic() - t0) * 1000:.0f}ms "
            f"(backend={_backend})"
        )
    except Exception as exc:
        logger.warning(f"Kokoro warmup failed: {exc}")
