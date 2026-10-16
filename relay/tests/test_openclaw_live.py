"""An opt-in live contract test of the OpenClaw gateway's /v1/responses
(OpenClaw 2026.9.2, password-mode auth: the password is sent as a bearer).

Skipped unless both are set:

    PARLEY_LIVE_OPENCLAW_URL         e.g. https://openclaw.<tailnet>
    PARLEY_LIVE_OPENCLAW_TOKEN_FILE  a file holding the gateway's password
                                     (/dev/stdin works: pipe it in)

and optionally PARLEY_LIVE_OPENCLAW_AGENT_ID. It sends three short turns to
the real agent under a fresh session (``parley:live-<random>``), plus one with
a wrong credential. The password is read once, never printed, and never put in
an assertion message.
"""

from __future__ import annotations

import os
import secrets

import httpx
import pytest

from parley_relay import style
from parley_relay.agent import AgentConversation, AgentError, OpenClawAgent, output_text

URL = os.environ.get("PARLEY_LIVE_OPENCLAW_URL", "").rstrip("/")
TOKEN_FILE = os.environ.get("PARLEY_LIVE_OPENCLAW_TOKEN_FILE", "")
AGENT_ID = os.environ.get("PARLEY_LIVE_OPENCLAW_AGENT_ID") or None

pytestmark = [
    pytest.mark.anyio,
    pytest.mark.skipif(not (URL and TOKEN_FILE),
                       reason="live OpenClaw contract: set PARLEY_LIVE_OPENCLAW_URL and PARLEY_LIVE_OPENCLAW_TOKEN_FILE"),
]


@pytest.fixture(scope="module")
def password() -> str:
    with open(TOKEN_FILE, encoding="utf-8") as fh:
        value = fh.read().strip()
    assert value, "the token file is empty"
    return value


def adapter(password: str) -> OpenClawAgent:
    async def token() -> str:
        return password

    return OpenClawAgent(URL, token=token, agent_id=AGENT_ID, timeout=300.0)


async def test_the_response_object_has_the_shape_the_adapter_reads(password):
    """The raw contract: a completed response whose text is in ``output_text``
    or in the ``output_text`` parts of ``output[].content[]`` (the two shapes
    agent.output_text reads). Prints which one 2026.9.2 sends."""
    body = {"model": f"openclaw/{AGENT_ID}" if AGENT_ID else "openclaw",
            "input": "Reply with the single word: ready.", "instructions": style.instructions(),
            "user": f"parley:live-{secrets.token_hex(4)}", "stream": False}
    headers = {"authorization": f"Bearer {password}"}
    if AGENT_ID:
        headers["x-openclaw-agent-id"] = AGENT_ID
    async with httpx.AsyncClient(timeout=300.0) as c:
        resp = await c.post(f"{URL}/v1/responses", json=body, headers=headers)
    assert resp.status_code == 200, f"HTTP {resp.status_code}"
    data = resp.json()
    assert isinstance(data, dict) and data.get("status") in ("completed", "incomplete"), data.get("status")
    top = isinstance(data.get("output_text"), str) and bool(data["output_text"].strip())
    parts = [part for item in data.get("output") or [] if isinstance(item, dict) and item.get("type") == "message"
             for part in item.get("content") or [] if isinstance(part, dict)]
    nested = any(p.get("type") == "output_text" and str(p.get("text") or "").strip() for p in parts)
    assert top or nested, "no output_text at the top level or in output[].content[]"
    print(f"\nOpenClaw /v1/responses: status={data.get('status')} top-level output_text={top} "
          f"output[].content[] output_text={nested} content types={sorted({str(p.get('type')) for p in parts})}")
    assert output_text(data).strip()


async def test_the_adapter_keeps_the_conversation_in_one_session(password):
    agent = adapter(password)
    conv = AgentConversation(f"live-{secrets.token_hex(4)}")
    word = secrets.choice(["lantern", "harbor", "meadow", "copper", "willow"])
    try:
        first = await agent.send_turn(conv, f"Please remember this word for my next message: {word}. "
                                            "Just say that you will.")
        assert first.strip()
        second = await agent.send_turn(conv, "Which word did I ask you to remember? Answer with the word.")
    finally:
        await agent.aclose()
    assert word in second.lower(), "the second turn did not see the first (the user field's session)"


async def test_a_wrong_credential_is_refused_and_not_retried():
    agent = adapter("not-the-gateway-password")
    try:
        with pytest.raises(AgentError) as exc:
            await agent.send_turn(AgentConversation(f"live-{secrets.token_hex(4)}"), "hello")
    finally:
        await agent.aclose()
    assert exc.value.code == "agent_refused" and not exc.value.retryable
