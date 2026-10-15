"""Telling the phone a reply is ready. P2 adds APNs; P1 has the interface and
fakes. A push carries only ids and a fixed alert, never reply text: pushes pass
through Apple."""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Protocol

REPLY_READY_ALERT = "Reply ready"


def reply_ready_payload(conversation_id: str, turn_id: str) -> dict:
    return {
        "aps": {"alert": REPLY_READY_ALERT, "sound": "default"},
        "conversation_id": conversation_id,
        "turn_id": turn_id,
    }


class PushSender(Protocol):
    async def reply_ready(self, conversation_id: str, turn_id: str) -> None: ...


class NoopPushSender:
    async def reply_ready(self, conversation_id: str, turn_id: str) -> None:
        return None


@dataclass
class RecordingPushSender:
    """Records each payload it would send, for tests and ``--dev``."""

    sent: list[dict] = field(default_factory=list)

    async def reply_ready(self, conversation_id: str, turn_id: str) -> None:
        self.sent.append(reply_ready_payload(conversation_id, turn_id))
