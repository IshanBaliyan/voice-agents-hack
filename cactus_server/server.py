"""
Cactus Model Server

Standalone FastAPI server that loads Gemma 4 via Cactus FFI and handles
inference sessions over WebSocket.  The relay server connects here as a
WebSocket client, forwarding messages from iOS devices.

Run with:
    uvicorn cactus_server.server:app --port 8001

Protocol (per WebSocket session):
    Server → Client on connect:
        {"type": "status", "status": "ready"}

    Client → Server (messages):
        {"type": "audio",  "data": "<base64>", "audio_format": "pcm16_base64"}
        {"type": "image",  "data": "<base64>"}
        {"type": "system", "data": ""}

    Server → Client (responses):
        {"timestamp": <ms>, "type": "token", "data": "<base64 UTF-8>"}  (streamed, per decoded token)
        {"timestamp": <ms>, "type": "audio", "data": "<base64 PCM16>"}  (final TTS blob)
        {"timestamp": <ms>, "type": "text",  "data": "<base64 UTF-8>"}  (fallback if TTS fails)

Environment variables:
    CACTUS_PYTHON_PATH  — path to cactus python directory
                          (default: <this dir>/vendor/python, which ships with the server)
    GEMMA4_MODEL_PATH   — absolute path to the Gemma 4 weights directory
"""

import asyncio
import base64
import importlib.util
import json
import logging
import os
import re
import struct
import subprocess
import tempfile
import time
import wave
from concurrent.futures import ThreadPoolExecutor
from contextlib import asynccontextmanager
from typing import Any, Callable, Dict, List, Optional

from fastapi import FastAPI, WebSocket, WebSocketDisconnect

# Load cactus_server/.env (if present) so GEMMA4_MODEL_PATH etc. are available
# when the server is launched directly via `uvicorn` (not just through Make).
try:
    from dotenv import load_dotenv
    load_dotenv(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".env"))
except ImportError:
    pass

logging.basicConfig(format='%(asctime)s %(message)s', level=logging.INFO)
logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Cactus FFI bootstrap
#
# Load src/cactus.py directly by file path so we never depend on sys.path
# resolution.  This works regardless of which Python environment (venv,
# conda, system) uvicorn is launched from.
# ---------------------------------------------------------------------------

_DEFAULT_CACTUS_PYTHON_PATH = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "vendor", "python"
)
_CACTUS_PYTHON_PATH = os.getenv("CACTUS_PYTHON_PATH", _DEFAULT_CACTUS_PYTHON_PATH)
_CACTUS_MODULE_FILE = os.path.join(_CACTUS_PYTHON_PATH, "src", "cactus.py")

try:
    _spec = importlib.util.spec_from_file_location("_cactus_ffi", _CACTUS_MODULE_FILE)
    if _spec is None or _spec.loader is None:
        raise ImportError(f"Cannot locate cactus module at {_CACTUS_MODULE_FILE}")
    _cactus_mod = importlib.util.module_from_spec(_spec)
    _spec.loader.exec_module(_cactus_mod)  # type: ignore[union-attr]
    cactus_init = _cactus_mod.cactus_init
    cactus_complete = _cactus_mod.cactus_complete
    _CACTUS_AVAILABLE = True
except Exception as _err:
    logger.error(
        "Cactus library not importable — model server will reject connections. "
        f"Error: {_err}"
    )
    cactus_init = None  # type: ignore[assignment]
    cactus_complete = None  # type: ignore[assignment]
    _CACTUS_AVAILABLE = False

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

_NAVIGATION_SYSTEM_PROMPT = (
    "Describe what you see." 
)

_GEMMA_SAMPLE_RATE = 16_000
_SILENCE_RMS_THRESHOLD = 100
_SILENCE_TRIGGER_SEC = 1.5
_MAX_CONVERSATION_TURNS = 10

# Single-worker executor — Cactus is not thread-safe
_executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix="cactus")

# ---------------------------------------------------------------------------
# Singleton model handle — loaded once on startup, reused across sessions
# ---------------------------------------------------------------------------

_shared_gemma_handle: Optional[int] = None
_model_lock: Optional[asyncio.Lock] = None


def _get_model_lock() -> asyncio.Lock:
    global _model_lock
    if _model_lock is None:
        _model_lock = asyncio.Lock()
    return _model_lock


async def _ensure_model_loaded() -> None:
    """Load Gemma 4 into the shared handle if not already loaded."""
    global _shared_gemma_handle

    gemma_path = os.getenv("GEMMA4_MODEL_PATH", "")
    if not gemma_path:
        raise RuntimeError(
            "GEMMA4_MODEL_PATH is not set. "
            "Export it before starting: export GEMMA4_MODEL_PATH=/path/to/gemma4"
        )

    async with _get_model_lock():
        if _shared_gemma_handle is not None:
            return

        loop = asyncio.get_running_loop()
        logger.info(f"Loading Gemma 4 model from: {gemma_path}")
        handle = await loop.run_in_executor(
            _executor,
            lambda: cactus_init(gemma_path, None, False),
        )
        _shared_gemma_handle = handle
        logger.info("Gemma 4 model loaded and ready")


# ---------------------------------------------------------------------------
# Audio helpers
# ---------------------------------------------------------------------------

def _rms_of_pcm16(pcm_bytes: bytes) -> float:
    """Return RMS amplitude of raw PCM16-LE bytes (range 0–32767)."""
    n = len(pcm_bytes) // 2
    if n == 0:
        return 0.0
    samples = struct.unpack(f"<{n}h", pcm_bytes[: n * 2])
    return (sum(s * s for s in samples) / n) ** 0.5


def _tts_to_pcm16(text: str) -> Optional[bytes]:
    """
    Synthesise *text* using macOS TTS (say + afconvert).

    Returns raw PCM16-LE at 16 kHz mono, or None on failure.
    """
    try:
        with tempfile.TemporaryDirectory() as tmpdir:
            aiff_path = os.path.join(tmpdir, "speech.aiff")
            wav_path = os.path.join(tmpdir, "speech.wav")

            subprocess.run(
                ["say", "-r", "175", "-o", aiff_path, "--", text],
                check=True, capture_output=True, timeout=30,
            )
            subprocess.run(
                [
                    "afconvert",
                    "-f", "WAVE",
                    "-d", f"LEI16@{_GEMMA_SAMPLE_RATE}",
                    aiff_path, wav_path,
                ],
                check=True, capture_output=True, timeout=30,
            )
            with wave.open(wav_path, "rb") as wf:
                return wf.readframes(wf.getnframes())
    except Exception as exc:
        logger.error(f"TTS synthesis failed: {exc}")
        return None


def _load_audio_convert() -> Callable:
    """Load convert_quest_audio_to_pcm16 directly from file, bypassing sys.path."""
    backend_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    module_file = os.path.join(backend_root, "app", "utils", "audio", "audio_convert.py")
    spec = importlib.util.spec_from_file_location("_audio_convert", module_file)
    if spec is None or spec.loader is None:
        raise ImportError(f"Cannot locate audio_convert at {module_file}")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)  # type: ignore[union-attr]
    return mod.convert_quest_audio_to_pcm16


# Loaded lazily on first quest_float32 audio chunk
_convert_quest_audio: Optional[Callable] = None


def _decode_audio(b64_data: str, audio_format: str) -> bytes:
    """
    Decode base64 audio into raw PCM16-LE bytes.

    audio_format: "quest_float32" | "pcm16_base64" | "pcm16_raw"
    """
    global _convert_quest_audio
    raw = base64.b64decode(b64_data)
    if audio_format == "quest_float32":
        if _convert_quest_audio is None:
            _convert_quest_audio = _load_audio_convert()
        b64_pcm16 = _convert_quest_audio(raw, input_format="float32")
        return base64.b64decode(b64_pcm16)
    return raw


def _resize_image(img_bytes: bytes, max_side: int = 560) -> bytes:
    """
    Resize image so its longest side is at most max_side pixels.

    Returns JPEG bytes.  560px is chosen because Gemma 4's SigLIP encoder
    upscales all inputs to its 560×560 native crop size anyway; sending
    something close to that avoids a second lossy resize step inside the
    model while keeping file size small.  EXIF orientation is corrected
    so the model sees the image right-side up.
    """
    try:
        from PIL import Image, ImageOps
        import io
        img = Image.open(io.BytesIO(img_bytes))
        # Apply EXIF orientation so the model sees the image right-side up
        img = ImageOps.exif_transpose(img)
        img = img.convert("RGB")
        w, h = img.size
        if max(w, h) > max_side:
            scale = max_side / max(w, h)
            img = img.resize((int(w * scale), int(h * scale)), Image.LANCZOS)
        buf = io.BytesIO()
        img.save(buf, format="JPEG", quality=85)
        return buf.getvalue()
    except Exception as exc:
        logger.warning(f"Image resize failed, using original: {exc}")
        return img_bytes


def _cleanup_files(paths: List[str]) -> None:
    for p in paths:
        try:
            os.unlink(p)
        except OSError:
            pass


def _log_cactus_debug(result: Dict[str, Any]) -> None:
    """Log timing / token-usage stats from a cactus_complete response."""
    if not isinstance(result, dict):
        return
    fields = (
        "cloud_handoff", "confidence",
        "time_to_first_token_ms", "total_time_ms",
        "prefill_tps", "decode_tps", "ram_usage_mb",
        "prefill_tokens", "decode_tokens", "total_tokens",
    )
    stats = {k: result[k] for k in fields if k in result}
    if stats:
        logger.info(f"Gemma 4 stats: {stats}")
    fn_calls = result.get("function_calls") or []
    if fn_calls:
        logger.info(f"Gemma 4 function_calls: {fn_calls}")


# ---------------------------------------------------------------------------
# Per-session inference state
# ---------------------------------------------------------------------------

class _CactusSession:
    """
    Manages one connected client's inference state.

    Accumulates audio/image buffers, fires inference on silence or an
    explicit "system" message, and pushes responses into an asyncio.Queue
    that the WebSocket sender drains.
    """

    def __init__(self, gemma_handle: int) -> None:
        self._handle = gemma_handle
        self._response_queue: asyncio.Queue = asyncio.Queue()
        self._force_process_event = asyncio.Event()

        self._audio_lock = asyncio.Lock()
        self._audio_buffer: List[bytes] = []
        self._last_audio_time: float = 0.0
        self._pending_images: List[str] = []

        self._conversation: List[Dict[str, Any]] = [
            {"role": "system", "content": _NAVIGATION_SYSTEM_PROMPT}
        ]
        self._processing_task: Optional[asyncio.Task] = None

    def start(self) -> None:
        self._processing_task = asyncio.create_task(
            self._processing_loop(), name="cactus_session_loop"
        )

    async def stop(self) -> None:
        if self._processing_task and not self._processing_task.done():
            self._processing_task.cancel()
            try:
                await self._processing_task
            except asyncio.CancelledError:
                pass
        _cleanup_files(self._pending_images)
        self._pending_images.clear()
        # Unblock any waiting sender
        await self._response_queue.put(None)

    async def handle_message(self, message: Dict[str, Any]) -> None:
        msg_type = message.get("type", "")
        b64_data = message.get("data", "")
        audio_format = message.get("audio_format", "pcm16_base64")

        if msg_type == "audio":
            try:
                pcm16 = _decode_audio(b64_data, audio_format)
                async with self._audio_lock:
                    self._audio_buffer.append(pcm16)
                    self._last_audio_time = time.monotonic()
            except Exception as exc:
                logger.warning(f"Failed to decode audio chunk: {exc}")

        elif msg_type == "image":
            try:
                img_bytes = base64.b64decode(b64_data)
                # Resize to 336px max — Gemma 4 uses a 896px SigLIP encoder with
                # 14×14 patches.  Images larger than ~336px can be sliced into
                # multiple tiles, flooding the context with contradictory partial
                # views and causing hallucinations.  336px fits in a single tile.
                img_bytes = _resize_image(img_bytes, max_side=560)
                # Only keep the LATEST frame — replace any queued image so the
                # model always reasons about the most recent scene, and multiple
                # accumulated frames can't confuse the vision encoder.
                if self._pending_images:
                    _cleanup_files(self._pending_images)
                    self._pending_images.clear()
                with tempfile.NamedTemporaryFile(
                    suffix=".jpg", delete=False, dir=tempfile.gettempdir()
                ) as f:
                    f.write(img_bytes)
                    self._pending_images.append(f.name)
                # Debug: save a copy to /tmp/debug_last_frame.jpg for inspection
                with open("/tmp/debug_last_frame.jpg", "wb") as dbg:
                    dbg.write(img_bytes)
                logger.info(
                    f"Image received and resized: {len(img_bytes):,} bytes"
                )
            except Exception as exc:
                logger.warning(f"Failed to decode image: {exc}")

        elif msg_type == "system":
            self._force_process_event.set()

        else:
            logger.warning(f"Unhandled message type: {msg_type!r}")

    # ------------------------------------------------------------------
    # Background processing loop
    # ------------------------------------------------------------------

    async def _processing_loop(self) -> None:
        while True:
            try:
                triggered_by_signal = False
                try:
                    await asyncio.wait_for(
                        self._force_process_event.wait(), timeout=0.5
                    )
                    triggered_by_signal = True
                    self._force_process_event.clear()
                except asyncio.TimeoutError:
                    pass

                if not triggered_by_signal:
                    async with self._audio_lock:
                        has_audio = bool(self._audio_buffer)
                        silent_for = time.monotonic() - self._last_audio_time
                    if not (has_audio and silent_for >= _SILENCE_TRIGGER_SEC):
                        continue

                await self._process_turn()

            except asyncio.CancelledError:
                break
            except Exception as exc:
                logger.error(f"Session loop error: {exc}", exc_info=True)

    async def _process_turn(self) -> None:
        async with self._audio_lock:
            audio_chunks = list(self._audio_buffer)
            self._audio_buffer.clear()

        images = list(self._pending_images)
        self._pending_images.clear()

        if not audio_chunks and not images:
            return

        loop = asyncio.get_running_loop()

        # Prepare audio
        pcm_data: Optional[bytes] = None
        if audio_chunks:
            pcm_data = b"".join(audio_chunks)
            rms = _rms_of_pcm16(pcm_data)
            logger.info(
                f"Turn: {len(pcm_data):,} bytes PCM16 (RMS={rms:.1f}), "
                f"{len(images)} image(s)"
            )
            if rms <= _SILENCE_RMS_THRESHOLD:
                logger.debug("Audio below silence threshold — skipping")
                pcm_data = None

        # The merged pass responds only when the user has spoken. An image-only
        # turn (force-processed with no speech) has no intent to reply to.
        if pcm_data is None:
            _cleanup_files(images)
            return

        logger.info(
            f"Merged turn — {len(images)} image(s) + "
            f"{len(pcm_data):,} bytes audio, running inference"
        )

        user_message: Dict[str, Any] = {
            "role": "user",
            "content": "Help me navigate based on what you see and hear.",
        }
        if images:
            user_message["images"] = images

        # Inference is stateless per turn: system prompt + current user turn
        # only. Multi-turn history was causing the model to echo the first
        # scene's description ("laptop on desk") across later turns because
        # the user content is constant and the assistant's prior reply
        # dominated the attention over the new vision soft tokens.
        messages_for_inference = [
            {"role": "system", "content": _NAVIGATION_SYSTEM_PROMPT},
            user_message,
        ]
        messages_json = json.dumps(messages_for_inference)

        # Still record the turn for logs / future debugging, without images.
        self._conversation.append(
            {"role": "user", "content": user_message["content"]}
        )
        self._trim_conversation()

        response_text = ""
        try:
            options_json = json.dumps({"max_tokens": 512, "temperature": 0.7})
            handle = self._handle
            pcm_for_complete = pcm_data

            # Token streaming: cactus_complete invokes on_token from the worker
            # thread as each token is decoded. We hop back to the event loop
            # via call_soon_threadsafe and push a {"type":"token", ...} frame
            # into the response queue so the relay → iOS client sees partial
            # text immediately, before the final TTS audio blob arrives.
            response_loop = asyncio.get_running_loop()
            response_queue = self._response_queue
            stream_started = time.monotonic()

            def on_token(token: str, _token_id: int) -> None:
                if not token:
                    return
                msg = {
                    "timestamp": int(time.time() * 1000),
                    "type": "token",
                    "data": base64.b64encode(token.encode("utf-8")).decode(),
                }
                response_loop.call_soon_threadsafe(response_queue.put_nowait, msg)

            raw_json = await loop.run_in_executor(
                _executor,
                lambda: cactus_complete(
                    handle, messages_json, options_json, None, on_token, pcm_for_complete
                ),
            )
            logger.info(
                f"Streaming inference finished in "
                f"{(time.monotonic() - stream_started) * 1000:.0f} ms"
            )
            result = json.loads(raw_json)
            _log_cactus_debug(result)
            if not result.get("success"):
                logger.error(f"Gemma 4 error: {result.get('error')}")
                response_text = "Sorry, I couldn't process that. Please try again."
            else:
                response_text = result.get("response", "").strip()
                logger.info(f"Gemma 4: {response_text!r}")
        except Exception as exc:
            logger.error(f"Gemma 4 inference error: {exc}")
            response_text = "Sorry, something went wrong. Please try again."
        finally:
            _cleanup_files(images)

        if not response_text:
            return

        self._conversation.append({"role": "assistant", "content": response_text})

        # TTS → PCM16 (runs in default thread pool, not the Cactus executor)
        logger.info("Running TTS…")
        timestamp = int(time.time() * 1000)
        pcm_response = await loop.run_in_executor(
            None, lambda: _tts_to_pcm16(response_text)
        )

        if pcm_response:
            logger.info(f"TTS OK ({len(pcm_response):,} bytes) — sending audio")
            await self._response_queue.put({
                "timestamp": timestamp,
                "type": "audio",
                "data": base64.b64encode(pcm_response).decode(),
            })
        else:
            logger.warning("TTS failed — sending text fallback")
            await self._response_queue.put({
                "timestamp": timestamp,
                "type": "text",
                "data": base64.b64encode(response_text.encode()).decode(),
            })

    def _trim_conversation(self) -> None:
        system_msgs = [m for m in self._conversation if m["role"] == "system"]
        other_msgs = [m for m in self._conversation if m["role"] != "system"]
        max_other = _MAX_CONVERSATION_TURNS * 2
        if len(other_msgs) > max_other:
            other_msgs = other_msgs[-max_other:]
        self._conversation = system_msgs + other_msgs


# ---------------------------------------------------------------------------
# FastAPI application
# ---------------------------------------------------------------------------

@asynccontextmanager
async def lifespan(app: FastAPI):
    if not _CACTUS_AVAILABLE:
        logger.error(
            "Cactus library unavailable — WebSocket connections will be rejected."
        )
    else:
        try:
            await _ensure_model_loaded()
        except Exception as exc:
            logger.error(f"Failed to pre-load Gemma 4 on startup: {exc}")
    yield


app = FastAPI(title="Cactus Model Server", lifespan=lifespan)


@app.get("/health")
async def health():
    loaded = _shared_gemma_handle is not None
    return {"status": "ready" if loaded else "loading", "model_loaded": loaded}


@app.websocket("/ws/cactus")
async def cactus_ws(websocket: WebSocket) -> None:
    """
    Accept one inference session from the relay server.

    Sends {"type": "status", "status": "ready"} immediately on connect
    because the model is pre-loaded at startup.
    """
    await websocket.accept()

    if not _CACTUS_AVAILABLE or _shared_gemma_handle is None:
        await websocket.send_text(json.dumps({
            "type": "status", "status": "error", "message": "Model not loaded",
        }))
        await websocket.close()
        return

    session = _CactusSession(_shared_gemma_handle)
    session.start()

    try:
        await websocket.send_text(json.dumps({"type": "status", "status": "ready"}))
        logger.info("Cactus session started")

        async def _recv_from_relay() -> None:
            while True:
                raw = await websocket.receive_text()
                try:
                    msg = json.loads(raw)
                    await session.handle_message(msg)
                except json.JSONDecodeError as exc:
                    logger.warning(f"Bad JSON from relay: {exc}")

        async def _send_to_relay() -> None:
            while True:
                response = await session._response_queue.get()
                if response is None:
                    break
                await websocket.send_text(json.dumps(response))

        await asyncio.gather(_recv_from_relay(), _send_to_relay())

    except WebSocketDisconnect:
        logger.info("Relay server disconnected from model server")
    except Exception as exc:
        logger.error(f"Cactus session error: {exc}", exc_info=True)
    finally:
        await session.stop()


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(app, host="0.0.0.0", port=8001)
