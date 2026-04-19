"""
Kokoro TTS wrapper.

Synthesises English text to 16 kHz PCM16-LE bytes so the iOS client's
existing AudioManager (which expects 16 kHz mono Int16) can play each
chunk via AVAudioPlayerNode.scheduleBuffer without any client changes.

Kokoro natively produces 24 kHz float32 audio; we resample to 16 kHz
with scipy.signal.resample_poly and quantise to int16.

Loaded lazily on the first call. If Kokoro isn't installed or fails to
initialise, callers get None back and can fall back to a different TTS.
"""

from __future__ import annotations

import logging
import threading
from typing import Optional

import numpy as np

logger = logging.getLogger(__name__)

_KOKORO_SAMPLE_RATE = 24_000
_TARGET_SAMPLE_RATE = 16_000
_DEFAULT_VOICE = "af_heart"

_pipeline = None
_pipeline_lock = threading.Lock()
_pipeline_failed = False


def _get_pipeline():
    """Initialise KPipeline once; return None on failure."""
    global _pipeline, _pipeline_failed
    if _pipeline is not None:
        return _pipeline
    if _pipeline_failed:
        return None
    with _pipeline_lock:
        if _pipeline is not None:
            return _pipeline
        if _pipeline_failed:
            return None
        try:
            from kokoro import KPipeline  # type: ignore
            logger.info("Initialising Kokoro TTS pipeline (lang_code='a')…")
            _pipeline = KPipeline(lang_code="a")
            logger.info("Kokoro TTS pipeline ready.")
        except Exception as exc:
            logger.error(f"Kokoro TTS unavailable: {exc}")
            _pipeline_failed = True
            return None
    return _pipeline


def synthesize_pcm16(text: str, voice: str = _DEFAULT_VOICE) -> Optional[bytes]:
    """
    Return raw PCM16-LE @ 16 kHz mono for *text*, or None on failure.
    Suitable for direct injection into the iOS AudioManager.playPCM16 path.
    """
    text = (text or "").strip()
    if not text:
        return None

    pipeline = _get_pipeline()
    if pipeline is None:
        return None

    try:
        from scipy.signal import resample_poly  # type: ignore
    except Exception as exc:
        logger.error(f"scipy.signal.resample_poly unavailable: {exc}")
        return None

    try:
        chunks: list[np.ndarray] = []
        for _, _, audio in pipeline(text, voice=voice, speed=1.0):
            arr = audio.detach().cpu().numpy() if hasattr(audio, "detach") else np.asarray(audio)
            chunks.append(arr.astype(np.float32, copy=False).reshape(-1))
        if not chunks:
            return None
        waveform = np.concatenate(chunks)
        # 24 kHz → 16 kHz via rational resampling (up=2, down=3).
        resampled = resample_poly(waveform, up=2, down=3)
        # Float32 [-1, 1] → Int16 PCM.
        pcm = np.clip(resampled, -1.0, 1.0)
        pcm = (pcm * 32767.0).astype(np.int16, copy=False)
        return pcm.tobytes()
    except Exception as exc:
        logger.error(f"Kokoro synthesis failed for text {text!r}: {exc}")
        return None
