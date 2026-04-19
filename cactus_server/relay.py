"""
Cactus-only WebSocket Relay

FastAPI app that accepts iOS client WebSocket connections and forwards
messages to the Cactus Model Server via CactusLocalHandler.

Run with:
    uvicorn cactus_server.relay:app --port 8000

Client WebSocket endpoint:
    ws://<host>:8000/ws?audio_format=pcm16_base64

Message formats (client ↔ relay ↔ model server):
    Client → Relay:
        {"timestamp": int, "type": "audio"|"image"|"system", "data": "<base64>"}
    Relay → Client:
        {"timestamp": int, "type": "audio"|"text", "data": "<base64>"}
    Chunked image frames:
        {"type": "image", "chunk_id": str, "chunk_index": int,
         "total_chunks": int, "data": "<chunk>", "timestamp": int?}
"""

import asyncio
import json
import logging
import time

from fastapi import FastAPI, WebSocket, WebSocketDisconnect

from .base_llm_handler import AudioFormat
from .cactus_handler import CactusLocalHandler

logger = logging.getLogger(__name__)


class ChunkConfig:
    """Outbound chunking for large payloads (images)."""

    MAX_CHUNK_SIZE = 64 * 1024
    CHUNKABLE_TYPES = {"image"}


class GeneralWebSocketRelay:
    """Relay one client WebSocket through a CactusLocalHandler."""

    def __init__(self) -> None:
        self.active_connections: dict[str, WebSocket] = {}
        self.llm_handlers: dict[str, CactusLocalHandler] = {}

    def _create_chunks(self, message: dict) -> list[dict]:
        msg_type = message.get("type")
        data = message.get("data", "")

        if msg_type not in ChunkConfig.CHUNKABLE_TYPES:
            return [message]

        data_size = len(data)
        if data_size <= ChunkConfig.MAX_CHUNK_SIZE:
            return [message]

        chunk_id = f"{int(time.time() * 1000000)}"
        total_chunks = (data_size + ChunkConfig.MAX_CHUNK_SIZE - 1) // ChunkConfig.MAX_CHUNK_SIZE
        chunks = []

        for i in range(total_chunks):
            start = i * ChunkConfig.MAX_CHUNK_SIZE
            end = min(start + ChunkConfig.MAX_CHUNK_SIZE, data_size)
            chunk = {
                "type": msg_type,
                "chunk_id": chunk_id,
                "chunk_index": i,
                "total_chunks": total_chunks,
                "data": data[start:end],
            }
            if "timestamp" in message:
                chunk["timestamp"] = message["timestamp"]
            chunks.append(chunk)

        logger.info(
            f"Chunked {msg_type} message: {data_size} bytes -> {total_chunks} chunks"
        )
        return chunks

    async def handle_client(
        self,
        websocket: WebSocket,
        audio_format: str = "pcm16_base64",
    ) -> None:
        await websocket.accept()

        client_id = str(id(websocket))
        self.active_connections[client_id] = websocket

        try:
            client_audio_format = AudioFormat(audio_format.lower())
        except ValueError as exc:
            error_msg = f"Invalid audio_format: {exc}"
            logger.error(error_msg)
            await websocket.send_text(json.dumps({"error": error_msg}))
            await websocket.close()
            return

        llm_handler = CactusLocalHandler()
        self.llm_handlers[client_id] = llm_handler

        try:
            logger.info(
                f"Client {client_id} connected — audio_format={audio_format}"
            )
            await llm_handler.connect()

            await websocket.send_text(json.dumps({
                "type": "status",
                "status": "connected",
                "provider": llm_handler.provider_name,
                "audio_format": audio_format,
            }))

            await asyncio.gather(
                self._forward_client_to_llm(websocket, llm_handler, client_id, client_audio_format),
                self._forward_llm_to_client(llm_handler, websocket, client_id, client_audio_format),
            )

        except WebSocketDisconnect:
            logger.info(f"Client {client_id} disconnected")
        except ConnectionError as exc:
            logger.info(f"LLM connection error for client {client_id}: {exc}")
        except Exception as exc:
            logger.error(f"Error handling client {client_id}: {exc}", exc_info=True)
        finally:
            await self._cleanup_client(client_id)

    async def _forward_client_to_llm(
        self,
        websocket: WebSocket,
        llm_handler: CactusLocalHandler,
        client_id: str,
        audio_format: AudioFormat,
    ) -> None:
        try:
            while True:
                raw = await websocket.receive_text()
                try:
                    message = json.loads(raw)
                except json.JSONDecodeError as exc:
                    logger.warning(f"Invalid JSON from client {client_id}: {exc}")
                    continue

                if not isinstance(message, dict):
                    logger.warning(f"Client {client_id} sent non-dict message")
                    continue
                if "type" not in message or "data" not in message:
                    logger.warning(
                        f"Client {client_id} missing 'type' or 'data' field"
                    )
                    continue

                await llm_handler.send_message(message, audio_format)
                logger.debug(
                    f"Forwarded {message['type']} from {client_id} to model server"
                )

        except WebSocketDisconnect:
            logger.info(f"Client {client_id} websocket disconnected (client→llm)")
            raise
        except ConnectionError as exc:
            logger.info(f"Model server closed while forwarding client {client_id}: {exc}")
            raise
        except RuntimeError as exc:
            if "not connected" in str(exc).lower():
                logger.info(f"Client {client_id} sent to disconnected handler")
            else:
                logger.error(f"Runtime error forwarding client {client_id}: {exc}")
            raise

    async def _forward_llm_to_client(
        self,
        llm_handler: CactusLocalHandler,
        websocket: WebSocket,
        client_id: str,
        audio_format: AudioFormat,  # noqa: ARG002
    ) -> None:
        try:
            while True:
                message = await llm_handler.receive_message(audio_format)
                for chunk in self._create_chunks(message):
                    chunk_type = chunk.get("type")
                    if chunk_type == "page_image":
                        logger.info(
                            f"Forwarding page_image to client {client_id} "
                            f"({len(chunk.get('data') or '')} base64 chars, "
                            f"{chunk.get('source')} p.{chunk.get('page')})"
                        )
                    else:
                        logger.debug(
                            f"Forwarding {chunk_type} chunk to client {client_id}"
                        )
                    await websocket.send_text(json.dumps(chunk))

        except WebSocketDisconnect:
            logger.info(f"Client {client_id} websocket disconnected (llm→client)")
            raise
        except ConnectionError as exc:
            logger.info(f"Model server closed for client {client_id}: {exc}")
            raise

    async def _cleanup_client(self, client_id: str) -> None:
        logger.info(f"Cleaning up client {client_id}")

        if client_id in self.llm_handlers:
            handler = self.llm_handlers[client_id]
            try:
                await handler.disconnect()
            except Exception as exc:
                logger.error(f"Error disconnecting handler for {client_id}: {exc}")
            del self.llm_handlers[client_id]

        if client_id in self.active_connections:
            del self.active_connections[client_id]

        logger.info(f"Cleanup complete for client {client_id}")


# ---------------------------------------------------------------------------
# FastAPI app
# ---------------------------------------------------------------------------

logging.basicConfig(format="%(asctime)s %(levelname)s %(message)s", level=logging.INFO)

app = FastAPI(title="Cactus Relay Server")
_relay = GeneralWebSocketRelay()


@app.get("/health")
async def health() -> dict:
    return {"status": "ok", "active_clients": len(_relay.active_connections)}


@app.websocket("/ws")
async def client_ws(websocket: WebSocket, audio_format: str = "pcm16_base64") -> None:
    await _relay.handle_client(websocket, audio_format=audio_format)


