import json

import httpx
import pytest
from starlette.applications import Starlette
from starlette.requests import Request
from starlette.responses import JSONResponse
from starlette.routing import Route

from parley_relay import style
from parley_relay.agent import AgentConversation, AgentError, FakeAgent, OpenClawAgent, output_text
from parley_relay.push import REPLY_READY_ALERT, RecordingPushSender

pytestmark = pytest.mark.anyio


def fake_gateway(reply, status=200):
    """A local stand-in for an OpenClaw gateway's POST /v1/responses."""
    seen = []

    async def responses(request: Request):
        seen.append({"headers": dict(request.headers), "body": json.loads(await request.body())})
        return JSONResponse(reply, status_code=status)

    return Starlette(routes=[Route("/v1/responses", responses, methods=["POST"])]), seen


OPENRESPONSES_REPLY = {
    "id": "resp_1", "object": "response", "status": "completed",
    "output": [
        {"type": "reasoning", "summary": []},
        {"type": "message", "role": "assistant",
         "content": [{"type": "output_text", "text": "Hello there. "}, {"type": "output_text", "text": "How are you?"}]},
    ],
}


async def gateway_token():
    return "test-gateway-token"


async def test_openclaw_adapter_sends_style_and_session_and_reads_the_reply():
    app, seen = fake_gateway(OPENRESPONSES_REPLY)
    agent = OpenClawAgent("http://gateway", token=gateway_token, agent_id="voice", transport=httpx.ASGITransport(app=app))
    reply = await agent.send_turn(AgentConversation("c123"), "What's up?")
    assert reply == "Hello there. How are you?"
    [call] = seen
    assert call["headers"]["authorization"] == "Bearer test-gateway-token"
    assert call["headers"]["x-openclaw-agent-id"] == "voice"
    assert call["body"]["model"] == "openclaw/voice"
    assert call["body"]["input"] == "What's up?"
    assert call["body"]["user"] == "parley:c123"
    assert call["body"]["instructions"] == style.instructions()
    assert call["body"]["stream"] is False


@pytest.mark.parametrize(("status", "code", "retryable"), [(503, "agent_busy", True), (401, "agent_refused", False)])
async def test_openclaw_adapter_errors(status, code, retryable):
    app, _ = fake_gateway({"error": {"message": "no"}}, status=status)
    agent = OpenClawAgent("http://gateway", token=gateway_token, transport=httpx.ASGITransport(app=app))
    with pytest.raises(AgentError) as exc:
        await agent.send_turn(AgentConversation("c"), "hi")
    assert exc.value.code == code and exc.value.retryable is retryable


def test_output_text_variants():
    assert output_text({"output_text": "Direct."}) == "Direct."
    with pytest.raises(AgentError):
        output_text({"status": "failed", "error": {"code": "x"}})
    with pytest.raises(AgentError):
        output_text({"status": "completed", "output": []})


async def test_fake_agent_is_deterministic_and_steerable():
    agent = FakeAgent()
    conv = AgentConversation("c1")
    a = await agent.send_turn(conv, "How should I plan my week?")
    assert a == await agent.send_turn(conv, "How should I plan my week?")
    assert "<attachment>" in await agent.send_turn(conv, "send me a link")
    assert len(await agent.send_turn(conv, "tell me something long")) > 2000
    assert "**" in await agent.send_turn(conv, "markdown please")
    with pytest.raises(AgentError):
        await agent.send_turn(conv, "please fail")


async def test_push_payload_carries_ids_only():
    push = RecordingPushSender()
    await push.reply_ready("c1", "t1")
    [payload] = push.sent
    assert payload == {"aps": {"alert": REPLY_READY_ALERT, "sound": "default"}, "conversation_id": "c1", "turn_id": "t1"}
