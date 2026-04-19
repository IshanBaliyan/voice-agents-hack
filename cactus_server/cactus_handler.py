"""
Cactus Relay Handler

WebSocket client proxy to the Cactus Model Server (cactus_server/server.py).
The relay creates one CactusLocalHandler per connected iOS client and proxies
messages in both directions.

Environment variables:
    CACTUS_MODEL_SERVER_URL — WebSocket URL of the model server
                              (default: ws://localhost:8001/ws/cactus)
"""

import asyncio
import json
import logging
import os
from typing import Any, Dict, Optional

import websockets
import websockets.exceptions

logger = logging.getLogger(__name__)

_CACTUS_MODEL_SERVER_URL = os.getenv(
    "CACTUS_MODEL_SERVER_URL", "ws://localhost:8001/ws/cactus"
)


class CactusLocalHandler:
    """
    Proxies a client session to the Cactus Model Server.

    connect() opens a WebSocket to the model server and waits for
    {"type": "status", "status": "ready"}. send_message() forwards client
    messages verbatim (with the audio_format embedded). A background task
    pumps server responses into a queue that receive_message() drains.
    """

    def __init__(self) -> None:
        self._model_server_url = _CACTUS_MODEL_SERVER_URL
        self._ws: Optional[websockets.WebSocketClientProtocol] = None
        self._is_connected: bool = False
        self._response_queue: asyncio.Queue = asyncio.Queue()
        self._recv_task: Optional[asyncio.Task] = None

    @property
    def is_connected(self) -> bool:
        return self._is_connected

    @property
    def provider_name(self) -> str:
        return "cactus_local"

    async def connect(self) -> None:
        if self._is_connected:
            logger.warning("CactusLocalHandler already connected")
            return

        try:
            self._ws = await websockets.connect(
                self._model_server_url,
                max_size=None,
            )
        except Exception as exc:
            raise ConnectionError(
                f"Cannot reach Cactus Model Server at {self._model_server_url}: {exc}"
            ) from exc

        try:
            raw = await asyncio.wait_for(self._ws.recv(), timeout=30.0)
            msg = json.loads(raw)
            if msg.get("type") == "status" and msg.get("status") == "error":
                await self._ws.close()
                raise ConnectionError(
                    f"Model server not ready: {msg.get('message', 'unknown error')}"
                )
            if not (msg.get("type") == "status" and msg.get("status") == "ready"):
                await self._response_queue.put(msg)
        except asyncio.TimeoutError as exc:
            await self._ws.close()
            raise ConnectionError("Timed out waiting for model server ready signal") from exc
        except json.JSONDecodeError as exc:
            await self._ws.close()
            raise ConnectionError(f"Invalid handshake from model server: {exc}") from exc

        self._is_connected = True
        self._recv_task = asyncio.create_task(
            self._recv_loop(), name="cactus_handler_recv"
        )
        logger.info(f"Connected to Cactus Model Server at {self._model_server_url}")

    async def disconnect(self) -> None:
        if not self._is_connected:
            return

        self._is_connected = False

        if self._recv_task and not self._recv_task.done():
            self._recv_task.cancel()
            try:
                await self._recv_task
            except asyncio.CancelledError:
                pass

        if self._ws:
            try:
                await self._ws.close()
            except Exception:
                pass
            self._ws = None

        await self._response_queue.put(None)
        logger.info("CactusLocalHandler disconnected")

    async def send_message(self, message: Dict[str, Any], audio_format: Any) -> None:
        if not self._is_connected or self._ws is None:
            raise RuntimeError("CactusLocalHandler is not connected")

        outgoing = dict(message)
        outgoing["audio_format"] = getattr(audio_format, "value", str(audio_format))

        try:
            await self._ws.send(json.dumps(outgoing))
        except websockets.exceptions.ConnectionClosed as exc:
            raise ConnectionError(f"Model server connection closed: {exc}") from exc

    async def receive_message(self, audio_format: Any) -> Dict[str, Any]:  # noqa: ARG002
        msg = await self._response_queue.get()
        if msg is None:
            raise ConnectionError("CactusLocalHandler session closed")
        return msg

    async def _recv_loop(self) -> None:
        try:
            assert self._ws is not None
            async for raw in self._ws:
                try:
                    msg = json.loads(raw)
                    if msg.get("type") == "status":
                        logger.debug(f"Model server status: {msg.get('status')}")
                        continue
                    await self._response_queue.put(msg)
                except json.JSONDecodeError as exc:
                    logger.warning(f"Invalid JSON from model server: {exc}")
        except websockets.exceptions.ConnectionClosed:
            logger.info("Model server WebSocket closed")
        except asyncio.CancelledError:
            pass
        except Exception as exc:
            logger.error(f"Model server recv loop error: {exc}")
        finally:
            await self._response_queue.put(None)
