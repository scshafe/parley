import base64
import logging

import httpx
import pytest

from parley_relay.agent import AgentConversation, AgentError
from parley_relay.oidc import ClientCredentials, TokenError
from parley_relay.secretfiles import SecretFile, SecretFileError
from parley_relay.server import ConfigError, Settings, build
from parley_relay.voicelab import SpeechClient, SpeechError, _refusal

from conftest import TEST_SECRET
from oidc_fakes import ISSUER, FakeProvider

pytestmark = pytest.mark.anyio


def provider_for(fake, tmp_path, clock=None, secret=None):
    path = tmp_path / "voicelab-client-secret"
    path.write_text((secret or fake.client_secret) + "\n")
    kw = {"clock": clock} if clock else {}
    return ClientCredentials(ISSUER, "parley-relay", SecretFile(str(path), "PARLEY_VOICELAB_CLIENT_SECRET_FILE"),
                             transport=fake.transport(), **kw), path


async def test_client_credentials_basic_auth_and_cache_until_exp_minus_60(tmp_path):
    fake = FakeProvider(expires_in=600)
    now = [1000.0]
    cc, _ = provider_for(fake, tmp_path, clock=lambda: now[0])
    t1 = await cc()
    [req] = fake.token_requests
    assert req["form"] == {"grant_type": "client_credentials"}
    assert req["authorization"] == "Basic " + base64.b64encode(b"parley-relay:test-client-secret").decode()
    now[0] += 539
    assert await cc() == t1 and len(fake.token_requests) == 1
    now[0] += 2  # 541 s: inside the last minute
    t2 = await cc()
    assert t2 != t1 and len(fake.token_requests) == 2


async def test_without_expires_in_the_jwt_exp_times_renewal(tmp_path):
    fake = FakeProvider(expires_in=None)
    cc, _ = provider_for(fake, tmp_path)
    await cc()
    await cc()
    assert len(fake.token_requests) == 1


async def test_the_secret_file_is_read_on_use(tmp_path):
    fake = FakeProvider()
    cc, path = provider_for(fake, tmp_path, secret="an-old-secret")
    with pytest.raises(TokenError) as exc:
        await cc()
    assert exc.value.code == "invalid_client" and not exc.value.retryable
    path.write_text("test-client-secret-rotated")
    fake.client_secret = "test-client-secret-rotated"
    assert await cc()
    path.unlink()
    cc.invalidate()
    with pytest.raises(TokenError) as exc:
        await cc()
    assert exc.value.code == "client_secret_unavailable"


async def test_provider_errors_are_retryable(tmp_path):
    fake = FakeProvider(token_status=503)
    cc, _ = provider_for(fake, tmp_path)
    with pytest.raises(TokenError) as exc:
        await cc()
    assert exc.value.retryable


def speech_api(statuses):
    """A voice-lab stand-in answering GET /api/v1/speech/<id> with the given
    statuses in turn, recording each bearer."""
    seen = []

    def handler(request):
        seen.append(request.headers.get("authorization"))
        status = statuses.pop(0)
        if status == 401:
            return httpx.Response(401, json={"error": "unauthorized", "detail": "A bearer token is required."})
        return httpx.Response(200, json={"id": "sp-1", "state": "queued"})

    return httpx.MockTransport(handler), seen


async def test_a_401_from_voice_lab_refreshes_the_token_once(tmp_path):
    fake = FakeProvider()
    cc, _ = provider_for(fake, tmp_path)
    transport, seen = speech_api([401, 200])
    client = SpeechClient("http://voice-lab", token=cc, transport=transport)
    assert (await client.status("sp-1"))["state"] == "queued"
    assert len(fake.token_requests) == 2 and seen[0] != seen[1]
    transport, seen = speech_api([401, 401])
    client = SpeechClient("http://voice-lab", token=cc, transport=transport)
    with pytest.raises(SpeechError) as exc:
        await client.status("sp-1")
    assert exc.value.code == "unauthorized" and len(seen) == 2  # once, not a loop


async def test_a_token_failure_is_a_speech_error(tmp_path):
    fake = FakeProvider(token_status=503)
    cc, _ = provider_for(fake, tmp_path)
    client = SpeechClient("http://voice-lab", token=cc, transport=speech_api([200])[0])
    with pytest.raises(SpeechError) as exc:
        await client.status("sp-1")
    assert exc.value.code == "caller_token_unavailable" and exc.value.retryable


@pytest.mark.parametrize("body", [
    {"error": "gpu_busy", "detail": "The GPU is busy."},          # voice-lab's ApiRefusal
    {"code": "gpu_busy", "detail": "The GPU is busy."},           # P1's guess
    {"error": {"code": "gpu_busy", "detail": "The GPU is busy."}},
])
def test_refusal_shapes(body):
    err = _refusal(httpx.Response(503, json=body, headers={"retry-after": "30"}))
    assert (err.code, err.detail, err.retryable, err.retry_after) == ("gpu_busy", "The GPU is busy.", True, 30.0)


def test_secret_file_errors_name_the_setting_only(tmp_path):
    path = tmp_path / "s"
    path.write_text("   \n")
    with pytest.raises(SecretFileError) as exc:
        SecretFile(str(path), "PARLEY_X_FILE").get()
    assert "PARLEY_X_FILE" in str(exc.value)
    assert SecretFile(str(tmp_path / "absent"), "PARLEY_X_FILE").get() is None


# --- real mode wiring ------------------------------------------------------------------


def real_env(tmp_path, **over):
    sec = tmp_path / "secrets"
    sec.mkdir(exist_ok=True)
    env = {
        "PARLEY_DATA_DIR": str(tmp_path / "data"),
        "PARLEY_PUBLIC_URL": "https://parley.example.ts.net",
        "PARLEY_OIDC_ISSUER": ISSUER,
        "PARLEY_OIDC_AUDIENCE": "parley-ios",
        "PARLEY_OWNER_SUBJECT": "owner-subject",
        "PARLEY_TRUSTED_PROXY": "10.253.92.10",
        "PARLEY_OPENCLAW_URL": "https://openclaw.example.ts.net",
        "PARLEY_OPENCLAW_TOKEN_FILE": str(sec / "openclaw-gateway-token"),
        "PARLEY_VOICELAB_URL": "https://voice-lab.example.ts.net",
        "PARLEY_VOICELAB_CLIENT_ID": "parley-relay",
        "PARLEY_VOICELAB_CLIENT_SECRET_FILE": str(sec / "voicelab-client-secret"),
        "PARLEY_WEBHOOK_SECRET_FILE": str(sec / "voicelab-webhook-secret"),
    }
    env.update(over)
    return env, sec


async def test_real_mode_starts_without_secret_files_and_names_integrations_only(tmp_path, caplog):
    env, sec = real_env(tmp_path)
    (sec / "voicelab-client-secret").write_text("do-not-log-this-secret")
    with caplog.at_level(logging.INFO, logger="parley"):
        r = build(Settings.from_env(env=env))
    line = next(m for m in caplog.messages if m.startswith("parley-relay: app auth"))
    assert "Pocket ID bearer" in line and "door peer checked" in line
    assert "openclaw (file missing)" in line and "client credentials, file present" in line
    assert "webhook: on (file missing)" in line and "push: off" in line
    assert "do-not-log-this-secret" not in " ".join(caplog.messages)
    assert r.pipeline.settings.callback_url == "https://parley.example.ts.net/hooks/voice-lab"
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=r.app), base_url="http://relay") as c:
        assert (await c.get("/healthz")).json() == {"ok": True}
        assert (await c.get("/api/v1/conversations")).status_code == 403  # not from the door
        hook = await c.post("/hooks/voice-lab", content=b"{}", headers={"webhook-id": "m", "webhook-timestamp": "1",
                                                                       "webhook-signature": "v1,AAAA"})
        assert hook.status_code == 503  # no secret file yet
        (sec / "voicelab-webhook-secret").write_text(TEST_SECRET)  # placed later: no restart
        hook = await c.post("/hooks/voice-lab", content=b"{}", headers={"webhook-id": "m", "webhook-timestamp": "1",
                                                                       "webhook-signature": "v1,AAAA"})
        assert hook.status_code == 401
    with pytest.raises(AgentError) as exc:  # the gateway password is not placed yet
        await r.agent.send_turn(AgentConversation("c"), "hi")
    assert exc.value.code == "agent_unconfigured" and not exc.value.retryable
    r.store.close()


@pytest.mark.parametrize("missing", ["PARLEY_OIDC_ISSUER", "PARLEY_OWNER_SUBJECT", "PARLEY_VOICELAB_URL"])
def test_real_mode_refuses_to_start_without_its_identity_settings(tmp_path, missing):
    env, _ = real_env(tmp_path)
    del env[missing]
    with pytest.raises(ConfigError) as exc:
        build(Settings.from_env(env=env))
    assert missing in str(exc.value)


def test_the_p1_token_file_is_dev_only(tmp_path):
    env, _ = real_env(tmp_path, PARLEY_TOKEN_FILE=str(tmp_path / "nope"))
    assert Settings.from_env(env=env).token is None  # ignored (and never read) outside --dev
