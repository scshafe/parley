"""The agent behind Parley, through one adapter interface:
``send_turn(conversation, text) -> reply text``.

- :class:`OpenClawAgent` calls an OpenClaw gateway's OpenResponses surface,
  ``POST /v1/responses`` (docs.openclaw.ai/gateway/openresponses-http-api). The
  style instructions go in ``instructions``; the conversation's continuity is
  OpenClaw's own session, keyed by the ``user`` field (``parley:<conversation>``).
- :class:`FakeAgent` answers with canned, speech-style replies, for tests and
  ``--dev``.
"""

from __future__ import annotations

import asyncio
import hashlib
from collections.abc import Awaitable, Callable
from dataclasses import dataclass
from typing import Protocol

import httpx

from . import style


@dataclass(frozen=True)
class AgentConversation:
    id: str
    title: str | None = None

    @property
    def session_user(self) -> str:
        return f"parley:{self.id}"


class AgentError(Exception):
    def __init__(self, code: str, detail: str = "", *, retryable: bool = False) -> None:
        super().__init__(f"{code}: {detail}" if detail else code)
        self.code = code
        self.detail = detail
        self.retryable = retryable


class AgentAdapter(Protocol):
    async def send_turn(self, conversation: AgentConversation, text: str) -> str: ...


TokenProvider = Callable[[], Awaitable[str | None]]


class OpenClawAgent:
    """An OpenClaw gateway as Parley's agent. The gateway token is an operator
    credential for the whole gateway: the relay holds it, the phone never sees
    it, and it is never logged."""

    def __init__(self, base_url: str, *, token: TokenProvider, agent_id: str | None = None,
                 style_version: str = style.CURRENT, transport: httpx.AsyncBaseTransport | None = None,
                 timeout: float = 600.0) -> None:
        self._client = httpx.AsyncClient(base_url=base_url.rstrip("/"), transport=transport, timeout=timeout)
        self._token = token
        self._agent_id = agent_id
        self._style_version = style_version

    async def aclose(self) -> None:
        await self._client.aclose()

    async def send_turn(self, conversation: AgentConversation, text: str) -> str:
        headers = {"content-type": "application/json"}
        token = await self._token()
        if token:
            headers["authorization"] = f"Bearer {token}"
        if self._agent_id:
            headers["x-openclaw-agent-id"] = self._agent_id
        body = {
            "model": f"openclaw/{self._agent_id}" if self._agent_id else "openclaw",
            "input": text,
            "instructions": style.instructions(self._style_version),
            "user": conversation.session_user,
            "stream": False,
        }
        try:
            resp = await self._client.post("/v1/responses", json=body, headers=headers)
        except httpx.HTTPError as exc:
            raise AgentError("agent_unreachable", type(exc).__name__, retryable=True) from exc
        if resp.status_code in (429, 502, 503, 504):
            raise AgentError("agent_busy", f"HTTP {resp.status_code}", retryable=True)
        if resp.status_code >= 400:
            raise AgentError("agent_refused", f"HTTP {resp.status_code}")
        try:
            data = resp.json()
        except ValueError as exc:
            raise AgentError("agent_bad_reply", "not JSON") from exc
        return output_text(data)


def output_text(data: object) -> str:
    """The assistant's text from an OpenResponses response object."""
    if not isinstance(data, dict):
        raise AgentError("agent_bad_reply", "not an object")
    status = data.get("status")
    if status in ("failed", "cancelled"):
        err = data.get("error") if isinstance(data.get("error"), dict) else {}
        raise AgentError("agent_failed", str(err.get("code") or status))
    if isinstance(data.get("output_text"), str) and data["output_text"].strip():
        return data["output_text"]
    parts: list[str] = []
    for item in data.get("output") or []:
        if not isinstance(item, dict) or item.get("type") != "message":
            continue
        if item.get("role", "assistant") != "assistant":
            continue
        for content in item.get("content") or []:
            if isinstance(content, dict) and content.get("type") in ("output_text", "text"):
                parts.append(str(content.get("text") or ""))
    text = "".join(parts).strip()
    if not text:
        raise AgentError("agent_empty_reply", str(status or ""))
    return text


# --- the fake ----------------------------------------------------------------------------

_OPENINGS = [
    "Good question.",
    "Let me think about that for a moment.",
    "Here is how I see it.",
    "Sure, I can help with that.",
]
_BODIES = [
    "The short answer is that it depends on what you want most. If speed matters, start small and "
    "build from there. If you care more about getting it right, take a little longer to plan the first step. "
    "Either way, you will learn a lot from the first try.",
    "I would break it into three parts. First, decide what done looks like. Second, find the one thing "
    "that blocks you today. Third, do that thing before anything else. The rest usually follows.",
    "There are two sides to this. On one hand, the simple approach is easy to change later. On the other, "
    "a careful start saves you from fixing the same problem twice. I lean toward the simple approach for now.",
    "Most people overthink this part. Pick a time, set a small goal, and check back with yourself at the "
    "end of the week. Small, steady steps beat one big push.",
]
_CLOSINGS = [
    "Does that help?",
    "Want me to go deeper on any part of it?",
    "Let me know how it goes.",
    "Tell me what you decide.",
]


class FakeAgent:
    """Canned replies written for speech, chosen deterministically from the turn's
    text. A few words steer it, to exercise the pipeline:

    - ``long``: a reply over 2,000 characters (several speech jobs);
    - ``link``: a reply with an ``<attachment>`` block;
    - ``markdown``: a reply with markdown the relay must clean up;
    - ``fail``: the agent fails.
    """

    def __init__(self, *, delay: float = 0.0) -> None:
        self.delay = delay
        self.calls: list[tuple[str, str]] = []

    async def send_turn(self, conversation: AgentConversation, text: str) -> str:
        self.calls.append((conversation.id, text))
        if self.delay:
            await asyncio.sleep(self.delay)
        words = text.lower().split()
        h = int(hashlib.sha256(text.encode()).hexdigest(), 16)
        opening = _OPENINGS[h % len(_OPENINGS)]
        body = _BODIES[(h // 7) % len(_BODIES)]
        closing = _CLOSINGS[(h // 49) % len(_CLOSINGS)]
        if "fail" in words:
            raise AgentError("agent_failed", "the fake agent was asked to fail")
        if "long" in words:
            return " ".join([opening] + [b for b in _BODIES] * 3 + [closing])
        if "link" in words:
            return (f"{opening} I found a page that explains it well. I've put the link on your screen. "
                    f"{closing}\n<attachment>\nhttps://example.com/guide\n</attachment>")
        if "markdown" in words:
            return (f"## {opening}\n\n- **First**, read the [guide](https://example.com/guide).\n"
                    f"- Then try `it` yourself.\n\n{closing}")
        return f"{opening} {body} {closing}"
