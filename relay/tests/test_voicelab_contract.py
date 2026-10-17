"""The fake voice-lab against voice-lab docs/SPEECH_API.md.

The examples below are copied from SPEECH_API.md §6 and §8 (ellipses filled in);
the fake must answer with the same fields and follow the documented rules, so a
relay tested against it behaves the same against the real service."""

import json

import httpx
import pytest

from parley_relay import audio
from parley_relay.fake_voicelab import FakeVoiceLab

TOKEN = "fake-voice-lab-token"
AUTH = {"authorization": f"Bearer {TOKEN}"}
CALLBACK = "https://parley.example.ts.net/hooks/voice-lab"

# §6 POST /api/v1/speech, the request.
EXAMPLE_REQUEST = {"text": "…", "format": "wav", "callback_url": "https://agent.<tailnet>.ts.net/hooks/voice-lab",
                   "idempotency_key": "reply-8f2c…", "client_ref": "conversation-12/turn-7"}
# §6 GET /api/v1/speech/{id}, the status (also the 202 answer's body).
EXAMPLE_STATUS = {"id": "sp-…", "state": "running", "client_ref": "…", "format": "wav",
                  "text_characters": 182, "created_at": "…", "started_at": "…", "finished_at": None,
                  "queue_ms": 410, "render_ms": None, "segment_count": 3,
                  "segments": [{"index": 1, "sha256": "…", "bytes": 140844, "duration_ms": 2933,
                                "audio": "/api/v1/speech/sp-…/segments/1/audio"}],
                  "audio": None, "error": None, "links": {"self": "…", "audio": "…", "events": "…", "cancel": "…"}}
# §8 the webhook event.
EXAMPLE_EVENT = {"type": "speech.succeeded", "timestamp": "2026-10-11T12:00:07Z",
                 "data": {"id": "sp-…", "state": "succeeded", "client_ref": "…", "segment_count": 3,
                          "audio": {"sha256": "…", "bytes": 581644, "duration_ms": 12116, "format": "wav"},
                          "error": None, "links": {"self": "…", "audio": "…", "events": "…", "cancel": "…"}}}

TEXT = "Hello there, this is the first sentence. Here is a second one for you. And a third to finish."


def request_body(**over):
    body = dict(EXAMPLE_REQUEST, text=TEXT, callback_url=CALLBACK, idempotency_key="turn-abc.1")
    body.update(over)
    return {k: v for k, v in body.items() if v is not None}


@pytest.fixture
def fake(secret):
    delivered = []

    async def deliver(url, headers, body):
        delivered.append((url, headers, body))
        return 204

    f = FakeVoiceLab(token=TOKEN, secret=secret, deliver=deliver, autorun=False)
    f.delivered = delivered
    return f


@pytest.fixture
async def client(fake):
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=fake.app), base_url="http://voice-lab") as c:
        yield c


pytestmark = pytest.mark.anyio


async def test_post_answers_202_with_the_documented_status_fields(client):
    r = await client.post("/api/v1/speech", json=request_body(), headers=AUTH)
    assert r.status_code == 202
    assert r.headers["cache-control"] == "no-store"
    body = r.json()
    assert set(body) == set(EXAMPLE_STATUS)
    assert body["state"] == "queued" and body["id"].startswith("sp-")
    assert set(body["links"]) == {"self", "audio", "events", "cancel"}
    assert body["links"]["self"] == f"/api/v1/speech/{body['id']}"
    assert body["client_ref"] == "conversation-12/turn-7"
    assert body["text_characters"] == len(TEXT)


async def test_status_and_segments_match_the_example_once_rendered(client, fake):
    job = (await client.post("/api/v1/speech", json=request_body(), headers=AUTH)).json()
    await fake.render(job["id"])
    st = (await client.get(f"/api/v1/speech/{job['id']}", headers=AUTH)).json()
    assert set(st) == set(EXAMPLE_STATUS)
    assert st["state"] == "succeeded" and st["segment_count"] == 3 == len(st["segments"])
    for i, seg in enumerate(st["segments"], start=1):
        assert set(seg) == set(EXAMPLE_STATUS["segments"][0])
        assert seg["index"] == i and seg["audio"].endswith(f"/segments/{i}/audio")
    assert set(st["audio"]) == set(EXAMPLE_EVENT["data"]["audio"])
    assert st["audio"]["duration_ms"] == sum(s["duration_ms"] for s in st["segments"])
    assert st["render_ms"] is not None and st["finished_at"] is not None


async def test_webhook_event_is_signed_and_shaped_like_the_example(client, fake, secret):
    from parley_relay.voicelab import verify_webhook

    job = (await client.post("/api/v1/speech", json=request_body(), headers=AUTH)).json()
    await fake.render(job["id"])
    [(url, headers, body)] = fake.delivered
    assert url == CALLBACK
    assert headers["webhook-id"] == f"msg_{job['id']}"
    verify_webhook(secret, headers, body)
    event = json.loads(body)
    assert set(event) == set(EXAMPLE_EVENT)
    assert set(event["data"]) == set(EXAMPLE_EVENT["data"])
    assert event["type"] == "speech.succeeded"
    assert "text" not in event["data"]


async def test_audio_is_24k_mono_16bit_and_served_with_ranges(client, fake):
    job = (await client.post("/api/v1/speech", json=request_body(), headers=AUTH)).json()
    early = await client.get(f"/api/v1/speech/{job['id']}/audio", headers=AUTH)
    assert early.status_code == 409 and early.json()["error"] == "audio_not_ready"
    await fake.render(job["id"])
    whole = await client.get(f"/api/v1/speech/{job['id']}/audio", headers=AUTH)
    assert whole.status_code == 200 and whole.headers["content-type"] == "audio/wav"
    assert whole.headers["etag"].strip('"') == (await client.get(f"/api/v1/speech/{job['id']}", headers=AUTH)).json()["audio"]["sha256"]
    meta = audio.info(whole.content)
    assert (meta.rate, meta.channels, meta.sample_width) == (24000, 1, 2)
    part = await client.get(f"/api/v1/speech/{job['id']}/audio", headers={**AUTH, "range": "bytes=0-99"})
    assert part.status_code == 206 and part.content == whole.content[:100]
    assert part.headers["content-range"] == f"bytes 0-99/{len(whole.content)}"
    bad = await client.get(f"/api/v1/speech/{job['id']}/audio", headers={**AUTH, "range": f"bytes={len(whole.content)}-"})
    assert bad.status_code == 416 and bad.headers["content-range"] == f"bytes */{len(whole.content)}"
    several = await client.get(f"/api/v1/speech/{job['id']}/audio", headers={**AUTH, "range": "bytes=0-1,5-9"})
    assert several.status_code == 200
    head = await client.head(f"/api/v1/speech/{job['id']}/audio", headers=AUTH)
    assert head.status_code == 200 and head.headers["content-length"] == str(len(whole.content))
    seg = await client.get(f"/api/v1/speech/{job['id']}/segments/1/audio", headers=AUTH)
    assert seg.status_code == 200 and audio.info(seg.content).rate == 24000
    beyond = await client.get(f"/api/v1/speech/{job['id']}/segments/4/audio", headers=AUTH)
    assert beyond.status_code == 404
    fake.expire(job["id"])
    gone = await client.get(f"/api/v1/speech/{job['id']}/audio", headers=AUTH)
    assert gone.status_code == 410 and gone.json()["error"] == "audio_expired"


async def test_idempotency_replay_and_conflict(client):
    a = await client.post("/api/v1/speech", json=request_body(), headers=AUTH)
    b = await client.post("/api/v1/speech", json=request_body(), headers=AUTH)
    assert a.status_code == 202 and b.status_code == 200 and a.json()["id"] == b.json()["id"]
    c = await client.post("/api/v1/speech", json=request_body(text="Something else entirely here."), headers=AUTH)
    assert c.status_code == 409 and c.json()["error"] == "idempotency_conflict"


@pytest.mark.parametrize(
    ("over", "status", "code"),
    [
        ({"text": ""}, 422, "invalid_request"),
        ({"text": "   "}, 422, "invalid_request"),
        ({"text": "x" * 2001}, 422, "invalid_request"),
        ({"text": "bell\x07"}, 422, "invalid_request"),
        ({"format": "ogg-opus"}, 422, "unsupported_format"),
        ({"format": "mp3"}, 422, "invalid_request"),
        ({"callback_url": "http://parley.example.ts.net/hooks/voice-lab"}, 422, "callback_not_allowed"),
        ({"callback_url": "https://evil.example.com/hooks/voice-lab"}, 422, "callback_not_allowed"),
        ({"callback_url": "https://parley.example.ts.net/hooks/other"}, 422, "callback_not_allowed"),
        ({"callback_url": "https://parley.example.ts.net/hooks/voice-lab?x=1"}, 422, "callback_not_allowed"),
        ({"callback_url": "https://parley.example.ts.net/hooks/..;/admin"}, 422, "callback_not_allowed"),
        ({"idempotency_key": "has space"}, 422, "invalid_request"),
        ({"client_ref": "r" * 201}, 422, "invalid_request"),
        ({"surprise": 1}, 422, "invalid_request"),
    ],
)
async def test_refusals(client, over, status, code):
    r = await client.post("/api/v1/speech", json=request_body(**over), headers=AUTH)
    assert r.status_code == status, r.text
    assert r.json()["error"] == code
    assert r.headers["cache-control"] == "no-store"


async def test_callback_may_extend_the_prefix_by_whole_segments(client):
    r = await client.post("/api/v1/speech", json=request_body(callback_url=CALLBACK + "/turn-1"), headers=AUTH)
    assert r.status_code == 202
    r = await client.post("/api/v1/speech",
                          json=request_body(callback_url=CALLBACK + "x", idempotency_key="k2"), headers=AUTH)
    assert r.status_code == 422


async def test_auth_limits_and_routing(client, fake):
    assert (await client.post("/api/v1/speech", json=request_body())).status_code == 401
    assert (await client.get("/api/v1/speech/sp-nope", headers=AUTH)).json()["error"] == "speech_not_found"
    assert (await client.get("/api/v1/speech/sp-nope/x/y/z", headers=AUTH)).status_code == 404
    assert (await client.delete("/api/v1/speech", headers=AUTH)).status_code == 405
    fake.gpu_busy_seconds = 600
    busy = await client.post("/api/v1/speech", json=request_body(idempotency_key="busy"), headers=AUTH)
    assert busy.status_code == 503 and busy.json()["error"] == "gpu_busy" and busy.headers["retry-after"] == "600"
    fake.gpu_busy_seconds = None
    for i in range(4):
        assert (await client.post("/api/v1/speech", json=request_body(idempotency_key=f"q{i}"), headers=AUTH)).status_code == 202
    full = await client.post("/api/v1/speech", json=request_body(idempotency_key="q5"), headers=AUTH)
    assert full.status_code == 429 and full.json()["error"] == "too_many_jobs"


async def test_cancel_and_failure(client, fake):
    job = (await client.post("/api/v1/speech", json=request_body(), headers=AUTH)).json()
    r = await client.post(f"/api/v1/speech/{job['id']}/cancel", headers=AUTH)
    assert r.status_code == 202 and r.json()["state"] == "cancelled"
    again = await client.post(f"/api/v1/speech/{job['id']}/cancel", headers=AUTH)
    assert again.status_code == 409 and again.json()["error"] == "already_finished"
    fake.fail_next = "render_failed"
    job2 = (await client.post("/api/v1/speech", json=request_body(idempotency_key="f1"), headers=AUTH)).json()
    await fake.render(job2["id"])
    st = (await client.get(f"/api/v1/speech/{job2['id']}", headers=AUTH)).json()
    assert st["state"] == "failed" and st["error"]["code"] == "render_failed" and set(st["error"]) == {"code", "detail"}
    assert st["audio"] is None


async def test_event_stream_sends_each_segment_then_the_terminal_event(client, fake):
    job = (await client.post("/api/v1/speech", json=request_body(), headers=AUTH)).json()
    await fake.render(job["id"])
    events = [chunk async for chunk in fake.event_stream(fake.jobs[job["id"]])]
    assert [e.split("\n")[1] for e in events] == ["event: segment.ready"] * 3 + ["event: speech.succeeded"]
    assert events[0].startswith("id: 1\n") and events[-1].startswith("id: end\n")
    resumed = [chunk async for chunk in fake.event_stream(fake.jobs[job["id"]], after=2)]
    assert len(resumed) == 2
    seg = json.loads(events[0].split("data: ", 1)[1])
    assert set(seg) == set(EXAMPLE_STATUS["segments"][0])


async def test_sentences_follow_the_documented_rule(client, fake):
    text = "Hi. Ok. This sentence is long enough. Short end."
    job = (await client.post("/api/v1/speech", json=request_body(text=text, idempotency_key="s"), headers=AUTH)).json()
    await fake.render(job["id"])
    # "Hi. Ok." are fragments under 12 characters: they join the next sentence.
    # "Short end." has no next sentence: it joins the one before (voice-lab's
    # split_sentences), so the whole text is one segment.
    assert fake.jobs[job["id"]].segment_count == 1
