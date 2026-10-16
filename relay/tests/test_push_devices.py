import asyncio
import json
import logging

import httpx
import pytest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec

from parley_relay.push import APNsSender
from parley_relay.server import DEV_TOKEN, Settings, build

from apns_fake import FakeAPNs

pytestmark = pytest.mark.anyio
AUTH = {"authorization": f"Bearer {DEV_TOKEN}"}
KEY_ID, TEAM_ID = "TESTKEY123", "TESTTEAM12"
TOKEN_A = "a" * 64
TOKEN_B = "b" * 64


class Devices:
    """The store's device interface, in memory."""

    def __init__(self, *devices):
        self.rows = [{"id": f"d_{i}", "token": t, "environment": env} for i, (t, env) in enumerate(devices)]
        self.pushes = []

    def devices(self):
        return list(self.rows)

    def delete_device(self, did):
        before = len(self.rows)
        self.rows = [d for d in self.rows if d["id"] != did]
        return len(self.rows) < before

    def record_push(self, did, status):
        self.pushes.append((did, status))

    def register_device(self, token, environment):
        for d in self.rows:
            if d["token"] == token:
                d["environment"] = environment
        return next(d for d in self.rows if d["token"] == token), False


@pytest.fixture
def key():
    return ec.generate_private_key(ec.SECP256R1())


def write_key(path, key):
    path.write_bytes(key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                                       serialization.NoEncryption()))
    return str(path)


@pytest.fixture
async def apns(key):
    fake = await FakeAPNs(key.public_key(), KEY_ID, TEAM_ID).start()
    yield fake
    await fake.stop()


def sender(store, key_file, fake, clock=None, **hosts):
    # HTTP/2 only (the sender's default): over http:// that is prior knowledge (h2c).
    return APNsSender(store, key_file=key_file, key_id=KEY_ID, team_id=TEAM_ID,
                      hosts=hosts or {"sandbox": fake.url, "production": fake.url},
                      **({"clock": clock} if clock else {}))


async def test_a_push_goes_to_every_device_over_http2_with_ids_only(tmp_path, key, apns):
    store = Devices((TOKEN_A, "sandbox"), (TOKEN_B, "sandbox"))
    s = sender(store, write_key(tmp_path / "apns-key.p8", key), apns)
    await s.reply_ready("c_1", "t_1")
    assert [r["device"] for r in apns.requests] == [TOKEN_A, TOKEN_B]
    req = apns.requests[0]
    assert req["body"] == {"aps": {"alert": "Reply ready", "sound": "default"}, "conversation_id": "c_1",
                           "turn_id": "t_1"}
    h = req["headers"]
    assert h["apns-topic"] == "com.scshafe.parley" and h["apns-push-type"] == "alert"
    assert h["apns-priority"] == "10" and int(h["apns-expiration"]) > 0 and h["apns-collapse-id"] == "t_1"
    assert store.pushes == [("d_0", 200), ("d_1", 200)] and s.sent == 2
    await s.aclose()


async def test_the_provider_token_is_reused_then_renewed(tmp_path, key, apns):
    now = [1_800_000_000.0]
    store = Devices((TOKEN_A, "sandbox"))
    s = sender(store, write_key(tmp_path / "k.p8", key), apns, clock=lambda: now[0])
    await s.reply_ready("c", "t1")
    now[0] += 49 * 60
    await s.reply_ready("c", "t2")
    now[0] += 2 * 60
    await s.reply_ready("c", "t3")
    tokens = [r["headers"]["authorization"] for r in apns.requests]
    assert tokens[0] == tokens[1] != tokens[2]
    await s.aclose()


async def test_an_expired_provider_token_is_renewed_once(tmp_path, key, apns):
    store = Devices((TOKEN_A, "sandbox"))
    s = sender(store, write_key(tmp_path / "k.p8", key), apns)
    apns.expire_next = 1
    await s.reply_ready("c", "t1")
    first, second = (r["headers"]["authorization"] for r in apns.requests)
    assert first != second and store.pushes == [("d_0", 200)]
    apns.expire_next = 5  # expired again and again: one renewal, then give up
    await s.reply_ready("c", "t2")
    assert len(apns.requests) == 4 and store.pushes[-1] == ("d_0", 403)
    await s.aclose()


async def test_the_provider_token_is_renewed_once_per_push_not_per_device(tmp_path, key, apns):
    store = Devices((TOKEN_A, "sandbox"), (TOKEN_B, "sandbox"))
    s = sender(store, write_key(tmp_path / "k.p8", key), apns)
    apns.expire_next = 10
    await s.reply_ready("c", "t")
    assert len(apns.requests) == 3  # A, A renewed, then B without another renewal
    assert store.pushes == [("d_0", 403), ("d_1", 403)]
    await s.aclose()


async def test_one_broken_device_does_not_stop_the_others(tmp_path, key, apns):
    store = Devices(("not a\nvalid token", "sandbox"), (TOKEN_B, "sandbox"))
    s = sender(store, write_key(tmp_path / "k.p8", key), apns)
    await s.reply_ready("c", "t")
    assert [r["device"] for r in apns.requests] == [TOKEN_B]
    await s.aclose()


@pytest.mark.parametrize(("status", "reason", "pruned"), [
    (410, "Unregistered", True),
    (400, "BadDeviceToken", False),  # also Apple's answer for the wrong environment's host
    (400, "PayloadTooLarge", False),
    (429, "TooManyRequests", False),
])
async def test_bad_device_tokens_are_forgotten(tmp_path, key, apns, status, reason, pruned):
    store = Devices((TOKEN_A, "sandbox"), (TOKEN_B, "sandbox"))
    apns.answers[TOKEN_A] = (status, reason)
    s = sender(store, write_key(tmp_path / "k.p8", key), apns)
    await s.reply_ready("c", "t")
    assert [d["token"] for d in store.rows] == ([TOKEN_B] if pruned else [TOKEN_A, TOKEN_B])
    await s.aclose()


async def test_bad_device_token_tries_the_other_environment_once(tmp_path, key, apns):
    prod = await FakeAPNs(key.public_key(), KEY_ID, TEAM_ID).start()
    try:
        store = Devices((TOKEN_A, "sandbox"), (TOKEN_B, "sandbox"))
        apns.answers[TOKEN_A] = (400, "BadDeviceToken")  # A is really a production device
        apns.answers[TOKEN_B] = (400, "BadDeviceToken")
        prod.answers[TOKEN_B] = (400, "BadDeviceToken")  # B is bad on both: kept, logged
        s = sender(store, write_key(tmp_path / "k.p8", key), apns, sandbox=apns.url, production=prod.url)
        await s.reply_ready("c", "t")
        assert [r["device"] for r in prod.requests] == [TOKEN_A, TOKEN_B]
        assert [(d["token"], d["environment"]) for d in store.rows] == [(TOKEN_A, "production"), (TOKEN_B, "sandbox")]
        assert store.pushes == [("d_0", 200), ("d_1", 400)]
        await s.aclose()
    finally:
        await prod.stop()


async def test_each_device_environment_picks_its_host(tmp_path, key, apns):
    prod = await FakeAPNs(key.public_key(), KEY_ID, TEAM_ID).start()
    try:
        store = Devices((TOKEN_A, "sandbox"), (TOKEN_B, "production"))
        s = sender(store, write_key(tmp_path / "k.p8", key), apns, sandbox=apns.url, production=prod.url)
        await s.reply_ready("c", "t")
        assert [r["device"] for r in apns.requests] == [TOKEN_A]
        assert [r["device"] for r in prod.requests] == [TOKEN_B]
        await s.aclose()
    finally:
        await prod.stop()


async def test_without_the_key_push_is_off_logged_once_and_turns_on_when_placed(tmp_path, key, apns, caplog):
    store = Devices((TOKEN_A, "sandbox"))
    path = tmp_path / "apns-key.p8"
    s = sender(store, str(path), apns)
    assert "key file missing" in s.describe() and not s.enabled
    with caplog.at_level(logging.INFO, logger="parley.push"):
        await s.reply_ready("c", "t1")
        await s.reply_ready("c", "t2")
        assert sum("push off" in m for m in caplog.messages) == 1
        assert apns.requests == []
        write_key(path, key)  # placed later: no restart
        await s.reply_ready("c", "t3")
    assert [r["body"]["turn_id"] for r in apns.requests] == ["t3"] and s.enabled
    assert TOKEN_A not in " ".join(caplog.messages)  # device tokens are never logged
    await s.aclose()


async def test_unconfigured_and_unreachable_push_never_raises(tmp_path, key):
    off = APNsSender(Devices((TOKEN_A, "sandbox")), key_file=None, key_id=None, team_id=None)
    assert off.describe().startswith("off") and not off.configured
    await off.reply_ready("c", "t")
    s = APNsSender(Devices((TOKEN_A, "sandbox")), key_file=write_key(tmp_path / "k.p8", key), key_id=KEY_ID,
                   team_id=TEAM_ID, hosts={"sandbox": "http://127.0.0.1:9"})
    await s.reply_ready("c", "t")  # connection refused: logged, not raised
    await s.aclose()
    bad = tmp_path / "bad.p8"
    bad.write_text("-----BEGIN PRIVATE KEY-----\nnot a key\n-----END PRIVATE KEY-----\n")
    s = APNsSender(Devices((TOKEN_A, "sandbox")), key_file=str(bad), key_id=KEY_ID, team_id=TEAM_ID)
    assert not s.enabled
    await s.reply_ready("c", "t")


# --- device registration and the whole turn ----------------------------------------------


@pytest.fixture
async def relay(tmp_path):
    r = build(Settings(dev=True, data_dir=tmp_path / "data", agent="fake", fake_agent_delay=0.0,
                       fake_speech_speed=0.0, poll_interval=0.05))
    yield r
    r.store.close()


def client_for(r):
    return httpx.AsyncClient(transport=httpx.ASGITransport(app=r.app), base_url="http://relay")


async def test_device_registration(relay):
    async with client_for(relay) as c:
        r = await c.post("/api/v1/devices", json={"token": TOKEN_A.upper(), "environment": "development"},
                         headers=AUTH)
        assert r.status_code == 201
        dev = r.json()
        assert dev["environment"] == "sandbox" and "token" not in dev and dev["id"].startswith("d_")
        again = await c.post("/api/v1/devices", json={"token": TOKEN_A, "environment": "production"}, headers=AUTH)
        assert again.status_code == 200 and again.json()["id"] == dev["id"]
        assert again.json()["environment"] == "production"
        assert (await c.post("/api/v1/devices", json={"token": TOKEN_B}, headers=AUTH)).json()["environment"] == "sandbox"
        for bad in ({"token": "xyz"}, {"token": TOKEN_A + "\n"}, {"token": TOKEN_A, "environment": "staging"}, {}):
            assert (await c.post("/api/v1/devices", json=bad, headers=AUTH)).status_code == 422
        listed = (await c.get("/api/v1/devices", headers=AUTH)).json()
        assert len(listed["devices"]) == 2 and TOKEN_A not in json.dumps(listed)
        assert (await c.delete(f"/api/v1/devices/{dev['id']}", headers=AUTH)).status_code == 204
        assert (await c.delete(f"/api/v1/devices/{dev['id']}", headers=AUTH)).status_code == 404
        assert (await c.post("/api/v1/devices", json={"token": TOKEN_A})).status_code == 401


async def test_a_ready_turn_is_pushed_to_the_registered_phone(relay, tmp_path, key, apns):
    relay.pipeline.push = sender(relay.store, write_key(tmp_path / "k.p8", key), apns)
    await relay.pipeline.start()
    async with client_for(relay) as c:
        assert (await c.post("/api/v1/devices", json={"token": TOKEN_A, "environment": "sandbox"},
                             headers=AUTH)).json()["push"] is True
        conv = (await c.post("/api/v1/conversations", json={}, headers=AUTH)).json()
        turn = (await c.post(f"/api/v1/conversations/{conv['id']}/turns",
                             json={"text": "Hello there", "client_turn_id": "ct-1"}, headers=AUTH)).json()
        for _ in range(500):
            if apns.requests:
                break
            await asyncio.sleep(0.01)
    await relay.pipeline.stop()
    [req] = apns.requests
    assert req["body"]["turn_id"] == turn["id"] and req["body"]["conversation_id"] == conv["id"]
    assert relay.store.get_turn(turn["id"])["pushed"] == 1
    assert relay.store.devices()[0]["last_push_status"] == 200
    await relay.pipeline.push.aclose()


async def test_a_push_that_raises_does_not_fail_the_turn(relay):
    class Broken:
        async def reply_ready(self, cid, tid):
            raise RuntimeError("boom")

    relay.pipeline.push = Broken()
    await relay.pipeline.start()
    async with client_for(relay) as c:
        conv = (await c.post("/api/v1/conversations", json={}, headers=AUTH)).json()
        turn = (await c.post(f"/api/v1/conversations/{conv['id']}/turns",
                             json={"text": "Hello there", "client_turn_id": "ct-1"}, headers=AUTH)).json()
        for _ in range(500):
            t = relay.store.get_turn(turn["id"])
            if t["pushed"]:
                break
            await asyncio.sleep(0.01)
    await relay.pipeline.stop()
    t = relay.store.get_turn(turn["id"])
    assert t["state"] == "ready" and t["pushed"] == 1


def test_apns_env_development_is_the_sandbox(tmp_path):
    env = {"PARLEY_DATA_DIR": str(tmp_path / "data"), "PARLEY_OIDC_ISSUER": "https://id.example.ts.net",
           "PARLEY_OWNER_SUBJECT": "o", "PARLEY_VOICELAB_URL": "https://voice-lab.example.ts.net",
           "PARLEY_AGENT": "fake", "PARLEY_APNS_ENV": "development"}
    s = Settings.from_env(env=env)
    r = build(s)
    assert s.apns_env == "sandbox"
    r.store.close()
