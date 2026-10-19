import time

import httpx
import pytest

from parley_relay.fake_voicelab import FakeVoiceLab
from parley_relay.voicelab import SpeechClient, SpeechError, WebhookError, WebhookSecret, verify_webhook

from conftest import TEST_SECRET

pytestmark = pytest.mark.anyio


async def _token():
    return "fake-voice-lab-token"


def make(fake):
    return SpeechClient("http://voice-lab", token=_token, transport=httpx.ASGITransport(app=fake.app))


async def test_create_status_audio_roundtrip():
    fake = FakeVoiceLab(autorun=False)
    client = make(fake)
    st = await client.create("A first sentence that is long. A second one here.", idempotency_key="turn-1",
                             client_ref="c/t")
    assert st["state"] == "queued"
    again = await client.create("A first sentence that is long. A second one here.", idempotency_key="turn-1",
                                client_ref="c/t")
    assert again["id"] == st["id"]
    with pytest.raises(SpeechError) as exc:
        await client.audio(st["id"])
    assert exc.value.code == "audio_not_ready" and not exc.value.retryable
    await fake.render(st["id"])
    done = await client.status(st["id"])
    assert done["state"] == "succeeded" and done["segment_count"] == 2
    assert (await client.audio(st["id"]))[:4] == b"RIFF"
    assert (await client.segment_audio(st["id"], 2))[:4] == b"RIFF"
    await client.aclose()


async def test_refusals_carry_codes_and_retry_hints():
    fake = FakeVoiceLab(autorun=False)
    fake.gpu_busy_seconds = 120
    client = make(fake)
    with pytest.raises(SpeechError) as exc:
        await client.create("Long enough text here.", idempotency_key="k")
    assert exc.value.code == "gpu_busy" and exc.value.retryable and exc.value.retry_after == 120
    bad = SpeechClient("http://voice-lab", transport=httpx.ASGITransport(app=fake.app))
    with pytest.raises(SpeechError) as exc:
        await bad.status("sp-x")
    assert exc.value.status == 401 and exc.value.code == "unauthorized"


async def test_network_errors_are_retryable():
    def boom(request):
        raise httpx.ConnectError("no route")

    client = SpeechClient("http://voice-lab", transport=httpx.MockTransport(boom))
    with pytest.raises(SpeechError) as exc:
        await client.status("sp-1")
    assert exc.value.code == "network_error" and exc.value.retryable


def test_webhook_secret_parsing():
    assert len(WebhookSecret.parse(TEST_SECRET).key) == 32
    for bad in ["nope", "whsec_!!!", "whsec_" + "QUJD"]:
        with pytest.raises(ValueError):
            WebhookSecret.parse(bad)


def test_webhook_verification(secret):
    body = b'{"type":"speech.succeeded"}'
    ts = int(time.time())
    headers = {"webhook-id": "msg_sp-1", "webhook-timestamp": str(ts),
               "webhook-signature": "v1,bm9wZQ== " + secret.sign("msg_sp-1", ts, body)}
    verify_webhook(secret, headers, body)
    with pytest.raises(WebhookError):
        verify_webhook(secret, headers, body + b" ")
    with pytest.raises(WebhookError):
        verify_webhook(secret, {**headers, "webhook-id": "msg_other"}, body)
    with pytest.raises(WebhookError):
        verify_webhook(secret, headers, body, now=ts + 301)
    with pytest.raises(WebhookError):
        verify_webhook(secret, {k: v for k, v in headers.items() if k != "webhook-signature"}, body)
    other = WebhookSecret(b"x" * 32)
    with pytest.raises(WebhookError):
        verify_webhook(other, headers, body)


async def test_segment_events_follow_a_job_and_resume_after_a_segment():
    fake = FakeVoiceLab(autorun=False)
    client = make(fake)
    st = await client.create("A first sentence that is long. A second one here.", idempotency_key="turn-ev")
    await fake.render(st["id"])
    seen = [(name, data.get("index")) async for name, data in client.segment_events(st["id"])]
    assert seen == [("segment.ready", 1), ("segment.ready", 2), ("speech.succeeded", None)]
    resumed = [name async for name, _ in client.segment_events(st["id"], after=1)]
    assert resumed == ["segment.ready", "speech.succeeded"]
    with pytest.raises(SpeechError) as exc:
        [x async for x in client.segment_events("sp-nope")]
    assert exc.value.code == "speech_not_found"
    await client.aclose()


async def test_a_running_job_does_not_leave_its_change_event_set():
    # A set event makes every event stream spin without yielding, which grew a
    # local dev relay's memory without bound (an OOM kill on 2026-10-19).
    import asyncio

    fake = FakeVoiceLab(autorun=False, speed=0.2)
    client = make(fake)
    st = await client.create("A first sentence that is long. A second one here.", idempotency_key="turn-spin")
    task = asyncio.create_task(fake.render(st["id"]))
    await asyncio.sleep(0.05)
    assert not fake.jobs[st["id"]].changed.is_set()
    seen = []

    async def follow():
        async for name, _ in client.segment_events(st["id"]):
            seen.append(name)

    await asyncio.wait_for(follow(), 10)
    await task
    assert seen[-1] == "speech.succeeded"
    await client.aclose()
