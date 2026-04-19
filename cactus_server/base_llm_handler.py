"""
Minimal LLM handler protocol.

Defines the interface the relay uses to talk to a backend model session.
This package only ships the Cactus-local handler, but the protocol is kept
so future handlers can be dropped in without touching the relay.
"""

from enum import Enum
from typing import Any, Dict, Protocol


class MessageType(Enum):
    """Types of messages exchanged over the client websocket."""

    TEXT = "text"
    AUDIO = "audio"
    IMAGE = "image"
    SYSTEM = "system"


class AudioFormat(Enum):
    """Supported client audio encodings."""

    QUEST_FLOAT32 = "quest_float32"
    PCM16_BASE64 = "pcm16_base64"
    PCM16_RAW = "pcm16_raw"


class LLMHandlerProtocol(Protocol):
    """Protocol every relay handler must implement."""

    async def connect(self) -> None: ...
    async def disconnect(self) -> None: ...
    async def send_message(self, message: Dict[str, Any], audio_format: Any) -> None: ...
    async def receive_message(self, audio_format: Any) -> Dict[str, Any]: ...

    @property
    def is_connected(self) -> bool: ...

    @property
    def provider_name(self) -> str: ...
