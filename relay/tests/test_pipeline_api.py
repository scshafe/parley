import asyncio
import json

import httpx
import pytest

from parley_relay import audio
from parley_relay.agent import FakeAgent
from parley_relay.api import event_stream
from parley_relay.pipeline import Pipeline, PipelineSettings
from parley_relay.server import DEV_TOKEN, Settings, build
from parley_relay.store import Store
from parley_relay.voicelab import WebhookSecret

pytestmark = pytest.mark.anyio
AUTH = {"authorization": f"Bearer {DEV_TOKEN}"}


def dev_settings(tmp_path, **over):
    s = Settings(dev=True, data_dir=tmp_path / "data", agent="fake", fake_agent_delay=0.0, fake_speech_speed=0.0,
                 poll_interval=0.05)
    for k, v in over.items():
        setattr(s, k, v)
    return s


@pytest.fixture
async def relay(tmp_path):
    r = build(dev_settings(tmp_path))
    await r.pipeline.start()
    yield r
    await r.pipeline.stop()
    r.store.close()


def client_for(r):
    return httpx.AsyncClient(transport=httpx.ASGITransport(app=r.app), base_url="http://relay")


async def settle(r, timeout=10.0):
    await asyncio.wait_for(r.pipeline.idle(), timeout)
    if r.fake_voicelab:
        await r.fake_voicelab.drain()
    await asyncio.wait_for(r.pipeline.idle(), timeout)


async def new_turn(c, text="How should I plan my week?", ctid="ct-1"):
    conv = (await c.post("/api/v1/conversations", json={}, headers=AUTH)).json()
    r = await c.post(f"/api/v1/conversations/{conv['id']}/turns", json={"text": text, "client_turn_id": ctid},
                     headers=AUTH)
    return conv, r


async def test_a_turn_goes_from_thinking_to_ready_with_audio_timings_and_push(relay):
    async with client_for(relay) as c:
        conv, r = await new_turn(c)
        assert r.status_code == 202
        turn = r.json()
        assert turn["state"] == "thinking" and turn["audio"] is None
        await settle(relay)
        got = (await c.get(f"/api/v1/conversations/{conv['id']}/turns/{turn['id']}", headers=AUTH)).json()
        assert got["state"] == "ready", got
        assert got["reply_text"] and got["style_version"] == "style-v1"
        assert got["audio"]["url"].endswith("/audio") and got["timings_url"].endswith("/timings.json")
        wav = await c.get(got["audio"]["url"], headers=AUTH)
        assert wav.status_code == 200 and wav.headers["content-type"] == "audio/wav"
        meta = audio.info(wav.content)
        assert meta.rate == 24000 and meta.duration_ms == got["audio"]["duration_ms"]
        part = await c.get(got["audio"]["url"], headers={**AUTH, "range": "bytes=44-"})
        assert part.status_code == 206 and part.content == wav.content[44:]
        timings = (await c.get(got["timings_url"], headers=AUTH)).json()
        assert timings["format"] == "parley.timings/v1" and timings["exact_sentences"] is True
        text = got["reply_text"]
        assert timings["text_length"] == len(text)
        words = [text[w["char_start"]:w["char_end"]] for w in timings["words"]]
        assert words == [w.strip(".,!?;:'\"") for w in text.split() if w.strip(".,!?;:'\"")]
        assert timings["sentences"][-1]["end_ms"] <= timings["duration_ms"]
        # The push names the ids only.
        assert relay.push.sent == [{"aps": {"alert": "Reply ready", "sound": "default"},
                                    "conversation_id": conv["id"], "turn_id": turn["id"]}]
        # The speech request followed the design.
        [req] = relay.fake_voicelab.requests
        assert req["idempotency_key"] == f"turn-{turn['id']}-1"
        assert req["client_ref"] == f"{conv['id']}/{turn['id']}"
        assert req["callback_url"].endswith("/hooks/voice-lab")
        assert req["text"] == text
        # Every state change is an event.
        events = relay.store.events_after(conv["id"], 0)
        states = [json.loads(e["data_json"])["state"] for e in events]
        assert [k for i, k in enumerate(states) if i == 0 or k != states[i - 1]] == ["thinking", "speaking", "ready"]
        listed = (await c.get("/api/v1/conversations", headers=AUTH)).json()["conversations"]
        assert listed[0]["id"] == conv["id"] and listed[0]["title"] == "How should I plan my week?"
        assert listed[0]["last_turn"]["state"] == "ready"
        full = (await c.get(f"/api/v1/conversations/{conv['id']}", headers=AUTH)).json()
        assert [t["id"] for t in full["turns"]] == [turn["id"]] and full["last_event_id"] == events[-1]["id"]


async def test_turn_retries_are_idempotent(relay):
    async with client_for(relay) as c:
        conv, first = await new_turn(c)
        again = await c.post(f"/api/v1/conversations/{conv['id']}/turns",
                             json={"text": "How should I plan my week?", "client_turn_id": "ct-1"}, headers=AUTH)
        assert again.status_code == 200 and again.json()["id"] == first.json()["id"]
        clash = await c.post(f"/api/v1/conversations/{conv['id']}/turns",
                             json={"text": "Something else", "client_turn_id": "ct-1"}, headers=AUTH)
        assert clash.status_code == 409 and clash.json()["error"]["code"] == "client_turn_conflict"
        await settle(relay)
        assert len(relay.agent.calls) == 1


async def test_auth_and_validation(relay):
    async with client_for(relay) as c:
        assert (await c.get("/healthz")).status_code == 200
        assert (await c.get("/api/v1/conversations")).status_code == 401
        assert (await c.get("/api/v1/conversations", headers={"authorization": "Bearer nope"})).status_code == 401
        assert (await c.get("/api/v1/conversations/c_missing", headers=AUTH)).status_code == 404
        conv = (await c.post("/api/v1/conversations", json={"title": "Plans"}, headers=AUTH)).json()
        assert conv["title"] == "Plans"
        for body in [{"text": "", "client_turn_id": "a"}, {"text": "hi", "client_turn_id": "bad id"},
                     {"text": "x" * 4001, "client_turn_id": "a"}, {"text": "hi"}]:
            r = await c.post(f"/api/v1/conversations/{conv['id']}/turns", json=body, headers=AUTH)
            assert r.status_code == 422, body
        r = await c.post(f"/api/v1/conversations/{conv['id']}/turns", content=b"not json", headers=AUTH)
        assert r.status_code == 422


async def test_audio_before_ready_is_409(tmp_path):
    r = build(dev_settings(tmp_path, fake_agent_delay=5.0))
    await r.pipeline.start()
    async with client_for(r) as c:
        conv, resp = await new_turn(c)
        tid = resp.json()["id"]
        a = await c.get(f"/api/v1/conversations/{conv['id']}/turns/{tid}/audio", headers=AUTH)
        assert a.status_code == 409 and a.json()["error"]["code"] == "audio_not_ready"
        t = await c.get(f"/api/v1/conversations/{conv['id']}/turns/{tid}/timings.json", headers=AUTH)
        assert t.status_code == 409
    await r.pipeline.stop()


async def test_a_long_reply_becomes_several_speech_jobs(relay):
    async with client_for(relay) as c:
        conv, r = await new_turn(c, text="Tell me something long please")
        await settle(relay)
        got = (await c.get(f"/api/v1/conversations/{conv['id']}/turns/{r.json()['id']}", headers=AUTH)).json()
        assert got["state"] == "ready" and len(got["reply_text"]) > 2000
        reqs = relay.fake_voicelab.requests
        assert len(reqs) >= 2 and all(len(q["text"]) <= 2000 for q in reqs)
        assert [q["idempotency_key"][-2:] for q in reqs] == [f"-{i}" for i in range(1, len(reqs) + 1)]
        timings = (await c.get(got["timings_url"], headers=AUTH)).json()
        ends = [s["end_ms"] for s in timings["sentences"]]
        assert ends == sorted(ends) and abs(ends[-1] - timings["duration_ms"]) <= 5
        wav = (await c.get(got["audio"]["url"], headers=AUTH)).content
        jobs_ms = sum(audio.info(relay.fake_voicelab.jobs[j].joined).duration_ms for j in relay.fake_voicelab.jobs)
        assert abs(audio.info(wav).duration_ms - jobs_ms) <= len(reqs)


async def test_markdown_and_links_are_cleaned_and_kept_aside(relay):
    async with client_for(relay) as c:
        conv, r = await new_turn(c, text="markdown please")
        await settle(relay)
        got = (await c.get(f"/api/v1/conversations/{conv['id']}/turns/{r.json()['id']}", headers=AUTH)).json()
        assert "**" not in got["reply_text"] and "#" not in got["reply_text"] and "http" not in got["reply_text"]
        assert "https://example.com/guide" in got["attachment"]
        assert {c["rule"] for c in got["cleanup"]} >= {"heading", "list", "emphasis", "link"}
        assert relay.fake_voicelab.requests[0]["text"] == got["reply_text"]


async def test_agent_failure_fails_the_turn(relay):
    async with client_for(relay) as c:
        conv, r = await new_turn(c, text="please fail now")
        await settle(relay)
        got = (await c.get(f"/api/v1/conversations/{conv['id']}/turns/{r.json()['id']}", headers=AUTH)).json()
        assert got["state"] == "failed" and got["error"]["code"] == "agent_failed"
        assert relay.push.sent == []


async def test_speech_failure_fails_the_turn(relay):
    relay.fake_voicelab.fail_next = "render_failed"
    async with client_for(relay) as c:
        conv, r = await new_turn(c)
        await settle(relay)
        got = (await c.get(f"/api/v1/conversations/{conv['id']}/turns/{r.json()['id']}", headers=AUTH)).json()
        assert got["state"] == "failed" and got["error"]["code"] == "speech_failed"
        assert "render_failed" in got["error"]["detail"]


async def test_a_busy_gpu_is_retried(tmp_path):
    r = build(dev_settings(tmp_path))
    r.fake_voicelab.gpu_busy_seconds = 30
    waits = []

    async def fake_sleep(seconds):
        waits.append(seconds)
        r.fake_voicelab.gpu_busy_seconds = None

    r.pipeline._sleep = fake_sleep
    await r.pipeline.start()
    async with client_for(r) as c:
        conv, resp = await new_turn(c)
        await settle(r)
        got = (await c.get(f"/api/v1/conversations/{conv['id']}/turns/{resp.json()['id']}", headers=AUTH)).json()
    assert got["state"] == "ready" and waits == [5.0]  # Retry-After, capped by the dev backoff cap
    await r.pipeline.stop()


async def test_the_webhook_wakes_the_turn_without_polling(tmp_path):
    r = build(dev_settings(tmp_path, poll_interval=1000.0))
    await r.pipeline.start()
    async with client_for(r) as c:
        conv, resp = await new_turn(c)
        await settle(r, timeout=5.0)
        got = (await c.get(f"/api/v1/conversations/{conv['id']}/turns/{resp.json()['id']}", headers=AUTH)).json()
    assert got["state"] == "ready"
    assert all(j.deliveries == [204] for j in r.fake_voicelab.jobs.values())
    await r.pipeline.stop()


async def test_webhook_signature_and_unknown_jobs(relay):
    secret: WebhookSecret = relay.fake_voicelab.secret
    body = json.dumps({"type": "speech.succeeded", "data": {"id": "sp-unknown", "client_ref": None}}).encode()
    import time

    ts = int(time.time())
    good = {"webhook-id": "msg_sp-unknown", "webhook-timestamp": str(ts),
            "webhook-signature": secret.sign("msg_sp-unknown", ts, body)}
    async with client_for(relay) as c:
        bad = await c.post("/hooks/voice-lab", content=body, headers={**good, "webhook-signature": "v1,AAAA"})
        assert bad.status_code == 401
        unknown = await c.post("/hooks/voice-lab", content=body, headers=good)
        assert unknown.status_code == 410


async def test_restart_resumes_a_turn_waiting_for_speech(tmp_path):
    s = dev_settings(tmp_path)
    r1 = build(s)
    fake = r1.fake_voicelab
    fake.autorun = False  # the job stays queued: voice-lab is slow
    await r1.pipeline.start()
    async with client_for(r1) as c:
        conv, resp = await new_turn(c)
        tid = resp.json()["id"]
        for _ in range(200):
            t = r1.store.get_turn(tid)
            if t["state"] == "speaking" and json.loads(t["jobs_json"])[0]["job_id"]:
                break
            await asyncio.sleep(0.01)
    await r1.pipeline.stop()  # the relay goes down mid-turn
    r1.store.close()

    store2 = Store(s.data_dir)
    t = store2.get_turn(tid)
    assert t["state"] == "speaking"
    [job_id] = list(fake.jobs)
    p2 = Pipeline(store2, FakeAgent(), r1.pipeline.speech, r1.push,
                  PipelineSettings(callback_url=None, poll_interval=0.02))
    await p2.start()
    await asyncio.sleep(0.05)
    await fake.render(job_id)  # voice-lab finishes after the restart
    await asyncio.wait_for(p2.idle(), 5)
    assert store2.get_turn(tid)["state"] == "ready"
    assert len(fake.jobs) == 1  # no second speech job
    assert len(r1.push.sent) == 1
    await p2.stop()
    store2.close()


async def test_restart_reposts_with_the_same_idempotency_key(tmp_path):
    """A crash after voice-lab accepted the job but before the relay recorded it:
    the repost answers the same job."""
    s = dev_settings(tmp_path)
    r = build(s)
    fake = r.fake_voicelab
    fake.autorun = False
    async with client_for(r) as c:
        conv, resp = await new_turn(c)
    tid = resp.json()["id"]
    # Do the agent step by hand, then post the speech job without recording it.
    await r.pipeline._think(r.store.get_turn(tid))
    t = r.store.get_turn(tid)
    first = await r.pipeline.speech.create(t["reply_text"], idempotency_key=f"turn-{tid}-1",
                                           client_ref=f"{conv['id']}/{tid}",
                                           callback_url=r.pipeline.settings.callback_url)
    fake.autorun = True
    await r.pipeline.start()
    await asyncio.sleep(0.05)
    await fake.render(first["id"])
    await settle(r)
    assert r.store.get_turn(tid)["state"] == "ready"
    assert list(fake.jobs) == [first["id"]]
    await r.pipeline.stop()


async def test_segment_ranges_from_voice_lab_are_used_when_reported(tmp_path):
    r = build(dev_settings(tmp_path))
    r.fake_voicelab.report_ranges = True
    r.fake_voicelab.max_sentence_chars = 30  # a rule the relay does not know: only the ranges can tell
    await r.pipeline.start()
    async with client_for(r) as c:
        conv, resp = await new_turn(c)
        await settle(r)
        got = (await c.get(f"/api/v1/conversations/{conv['id']}/turns/{resp.json()['id']}", headers=AUTH)).json()
        timings = (await c.get(got["timings_url"], headers=AUTH)).json()
    assert timings["exact_sentences"] is True
    assert len(timings["sentences"]) == len(next(iter(r.fake_voicelab.jobs.values())).segments)
    await r.pipeline.stop()


async def test_a_segment_mismatch_degrades_gracefully(tmp_path):
    r = build(dev_settings(tmp_path))
    r.fake_voicelab.max_sentence_chars = 30  # voice-lab cuts sentences the relay does not expect
    await r.pipeline.start()
    async with client_for(r) as c:
        conv, resp = await new_turn(c)
        await settle(r)
        got = (await c.get(f"/api/v1/conversations/{conv['id']}/turns/{resp.json()['id']}", headers=AUTH)).json()
        timings = (await c.get(got["timings_url"], headers=AUTH)).json()
    assert got["state"] == "ready" and got["timings_exact_sentences"] is False
    assert len(timings["sentences"]) == 1 and len(timings["words"]) > 5
    await r.pipeline.stop()


async def test_retention_sweep_deletes_old_audio(relay):
    async with client_for(relay) as c:
        conv, r = await new_turn(c)
        await settle(relay)
        tid = r.json()["id"]
        relay.store.update_turn(tid, ready_at="2000-01-01T00:00:00.000000Z")
        assert relay.pipeline.sweep() == 1
        got = (await c.get(f"/api/v1/conversations/{conv['id']}/turns/{tid}", headers=AUTH)).json()
        assert got["audio"]["available"] is False
        assert (await c.get(got["audio"]["url"], headers=AUTH)).status_code == 410
        assert (await c.get(got["timings_url"], headers=AUTH)).status_code == 200


async def test_event_stream_replays_then_follows(relay):
    async with client_for(relay) as c:
        conv, r = await new_turn(c)
        await settle(relay)
    chunks = []
    gen = event_stream(relay.store, relay.pipeline, conv["id"], 0, heartbeat=0.05, max_seconds=0.2)
    async for chunk in gen:
        chunks.append(chunk)
    assert chunks[0] == "retry: 2000\n\n"
    events = [ch for ch in chunks if ch.startswith("id: ")]
    assert len(events) >= 3 and all("event: turn.updated" in e for e in events)
    assert ": keep-alive\n\n" in chunks
    last_id = int(events[-1].split("\n")[0][4:])
    resumed = [ch async for ch in event_stream(relay.store, relay.pipeline, conv["id"], last_id, heartbeat=0.05,
                                                max_seconds=0.1)]
    assert not any(ch.startswith("id: ") for ch in resumed)


async def test_event_stream_wakes_on_a_new_turn(relay):
    async with client_for(relay) as c:
        conv = (await c.post("/api/v1/conversations", json={}, headers=AUTH)).json()
        seen = []

        async def listen():
            async for chunk in event_stream(relay.store, relay.pipeline, conv["id"], 0, heartbeat=5, max_seconds=5):
                if chunk.startswith("id: "):
                    seen.append(chunk)
                    if '"state":"ready"' in chunk:
                        return

        task = asyncio.create_task(listen())
        await asyncio.sleep(0.02)
        await c.post(f"/api/v1/conversations/{conv['id']}/turns", json={"text": "Hello there", "client_turn_id": "x"},
                     headers=AUTH)
        await asyncio.wait_for(task, 5)
    assert len(seen) == 3


async def test_the_database_snapshot_is_consistent_and_restores(tmp_path):
    import sqlite3

    r = build(dev_settings(tmp_path))
    await r.pipeline.start()
    async with client_for(r) as c:
        conv, resp = await new_turn(c)
        await settle(r)
    assert r.pipeline.snapshot_if_changed() is True
    assert r.pipeline.snapshot_if_changed() is False  # nothing written since
    await r.pipeline.stop()
    r.store.close()
    snap = tmp_path / "data" / "backup" / "relay.sqlite3"
    db = sqlite3.connect(snap)
    assert db.execute("PRAGMA integrity_check").fetchone()[0] == "ok"
    assert db.execute("PRAGMA journal_mode").fetchone()[0] == "delete"
    assert db.execute("SELECT state FROM turns").fetchall() == [("ready",)]
    db.close()
    # A restore: the live files are gone, the snapshot is there.
    for name in ("relay.sqlite3", "relay.sqlite3-wal", "relay.sqlite3-shm"):
        (tmp_path / "data" / name).unlink(missing_ok=True)
    store = Store(tmp_path / "data")
    assert store.get_turn(resp.json()["id"])["state"] == "ready"
    store.close()


async def test_conversations_are_searched_by_title_question_and_reply(relay):
    async with client_for(relay) as c:
        first, _ = await new_turn(c, "Remind me about the Budget review", "ct-a")
        second, _ = await new_turn(c, "What is the weather?", "ct-b")
        await settle(relay)
        found = (await c.get("/api/v1/conversations", params={"q": "budget"}, headers=AUTH)).json()["conversations"]
        assert [x["id"] for x in found] == [first["id"]]
        assert "Budget review" in found[0]["snippet"]
        reply = relay.store.turns_of(second["id"])[0]["reply_text"]
        word = reply.split()[0].strip(".,!?")
        hits = (await c.get("/api/v1/conversations", params={"q": word}, headers=AUTH)).json()["conversations"]
        assert second["id"] in [x["id"] for x in hits]
        none = (await c.get("/api/v1/conversations", params={"q": "zzzqqq"}, headers=AUTH)).json()
        assert none == {"conversations": []}
        bad = await c.get("/api/v1/conversations", params={"q": "  "}, headers=AUTH)
        assert bad.status_code == 422
        everything = (await c.get("/api/v1/conversations", headers=AUTH)).json()["conversations"]
        assert len(everything) == 2 and "snippet" not in everything[0]


async def test_sentences_are_streamed_while_the_reply_is_rendered(relay):
    async with client_for(relay) as c:
        conv, turn = await new_turn(c, "Tell me a long story please", "ct-seg")
        await settle(relay)
        done = (await c.get(f"/api/v1/conversations/{conv['id']}/turns/{turn.json()['id']}", headers=AUTH)).json()
        segs = done["segments"]
        assert segs and [s["index"] for s in segs] == list(range(1, len(segs) + 1))
        assert segs[0]["offset_ms"] == 0
        for a, b in zip(segs, segs[1:]):
            assert b["offset_ms"] == a["offset_ms"] + a["duration_ms"]
        # The streamed sentences are the whole reply: same length as the joined audio.
        assert segs[-1]["offset_ms"] + segs[-1]["duration_ms"] == done["audio"]["duration_ms"]
        first = await c.get(segs[0]["url"], headers=AUTH)
        assert first.status_code == 200 and first.headers["content-type"] == "audio/wav"
        assert audio.info(first.content).duration_ms == segs[0]["duration_ms"]
        assert (await c.get(segs[0]["url"].rsplit("/", 2)[0] + "/99/audio", headers=AUTH)).status_code == 404
        assert (await c.get(segs[0]["url"], headers={})).status_code == 401
        events = relay.store.events_after(conv["id"], 0)
        assert sum(1 for e in events if json.loads(e["data_json"])["segments"]) >= len(segs)


async def test_a_refused_segment_stream_leaves_the_turn_unaffected(relay):
    async def refuse(job_id, after=0):
        from parley_relay.voicelab import SpeechError
        raise SpeechError("too_many_streams", status=429, retryable=True)
        yield  # pragma: no cover

    relay.pipeline.speech.segment_events = refuse
    async with client_for(relay) as c:
        conv, turn = await new_turn(c, "Another one", "ct-429")
        await settle(relay)
        done = (await c.get(f"/api/v1/conversations/{conv['id']}/turns/{turn.json()['id']}", headers=AUTH)).json()
        assert done["state"] == "ready" and done["segments"] == []


async def test_segments_stream_while_a_slow_render_is_going(tmp_path):
    r = build(dev_settings(tmp_path, fake_speech_speed=0.05))
    await r.pipeline.start()
    try:
        async with client_for(r) as c:
            conv, turn = await new_turn(c, "Tell me about bread. Then about butter. And jam too.", "ct-slow")
            await settle(r)
            done = (await c.get(f"/api/v1/conversations/{conv['id']}/turns/{turn.json()['id']}", headers=AUTH)).json()
            assert done["state"] == "ready" and len(done["segments"]) >= 2
    finally:
        await r.pipeline.stop()
        r.store.close()
