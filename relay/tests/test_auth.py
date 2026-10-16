import json
import time

import httpx
import pytest

from parley_relay.api import build_app
from parley_relay.auth import AuthError, DoorAuth, JwksSource, JwtVerifier, StaticTokenAuth, parse_jwks
from parley_relay.server import Settings, build

from oidc_fakes import ISSUER, OWNER, FakeProvider, SigningKey, b64url, claims

pytestmark = pytest.mark.anyio
DOOR = "10.253.92.10"


def verifier(provider, **kw):
    keys = JwksSource(ISSUER, transport=provider.transport(), **kw)
    return JwtVerifier(keys, issuer=ISSUER, audiences=("parley-ios",), subjects=(OWNER,))


async def test_a_valid_bearer_names_the_owner():
    p = FakeProvider()
    assert (await verifier(p).verify(p.keys[0].sign(claims()))).subject == OWNER


async def test_es256_keys_are_accepted_too():
    p = FakeProvider(keys=[SigningKey("ec1", alg="ES256")])
    assert (await verifier(p).verify(p.keys[0].sign(claims(aud=["other", "parley-ios"])))).subject == OWNER


@pytest.mark.parametrize(("over", "code", "status"), [
    ({"aud": "parley"}, "invalid_token", 401),
    ({"iss": "https://evil.example"}, "invalid_token", 401),
    ({"exp": int(time.time()) - 3600}, "token_expired", 401),
    ({"exp": None}, "invalid_token", 401),
    ({"nbf": int(time.time()) + 3600}, "invalid_token", 401),
    ({"sub": "someone-else"}, "forbidden", 403),
])
async def test_claims_are_checked(over, code, status):
    p = FakeProvider()
    with pytest.raises(AuthError) as exc:
        await verifier(p).verify(p.keys[0].sign(claims(**over)))
    assert (exc.value.code, exc.value.status) == (code, status)


async def test_forged_and_malformed_tokens_are_refused():
    p = FakeProvider()
    v = verifier(p)
    other = SigningKey("k1")  # same kid, another key: a forgery
    for token in [other.sign(claims()), "not-a-jwt", "a.b", p.keys[0].sign(claims())[:-4] + "AAAA",
                  b64url(b'{"alg":"none"}') + "." + b64url(b'{}') + "."]:
        with pytest.raises(AuthError) as exc:
            await v.verify(token)
        assert exc.value.status == 401
    hs = p.keys[0].sign(claims(), header={"alg": "HS256"})
    with pytest.raises(AuthError):
        await v.verify(hs)


async def test_an_unknown_key_id_refetches_the_keys_once_a_minute():
    p = FakeProvider()
    now = [1000.0]
    v = verifier(p, clock=lambda: now[0])
    await v.verify(p.keys[0].sign(claims()))
    assert p.jwks_hits == 1
    rotated = SigningKey("k2")
    p.keys = [rotated]
    with pytest.raises(AuthError):  # within the minute: no refetch, unknown key
        await v.verify(rotated.sign(claims()))
    assert p.jwks_hits == 1
    now[0] += 61
    assert (await v.verify(rotated.sign(claims()))).subject == OWNER
    assert p.jwks_hits == 2


async def test_keys_unavailable_is_503():
    def down(request):
        raise httpx.ConnectError("no route")

    v = JwtVerifier(JwksSource(ISSUER, transport=httpx.MockTransport(down)), issuer=ISSUER,
                    audiences=("parley-ios",), subjects=(OWNER,))
    with pytest.raises(AuthError) as exc:
        await v.verify(FakeProvider().keys[0].sign(claims()))
    assert exc.value.status == 503


def test_jwks_parsing_skips_weak_and_foreign_keys():
    weak = {"kty": "RSA", "kid": "w", "n": b64url((2**1023 + 1).to_bytes(128, "big")), "e": "AQAB"}
    with pytest.raises(ValueError):
        parse_jwks(b'{"keys": [{"kty": "oct", "kid": "x", "k": "AAAA"}]}')
    with pytest.raises(ValueError):
        parse_jwks(('{"keys": [%s]}' % json.dumps(weak)).encode())


# --- through the app -------------------------------------------------------------------


@pytest.fixture
async def door_app(tmp_path):
    p = FakeProvider()
    r = build(Settings(dev=True, data_dir=tmp_path / "data", agent="fake", fake_agent_delay=0.0,
                       fake_speech_speed=0.0, poll_interval=0.05))
    auth = DoorAuth(verifier(p), owner_subject=OWNER, trusted_proxies=(DOOR,))
    app = build_app(store=r.store, pipeline=r.pipeline, auth=auth, webhook_secret=None)
    yield app, p
    r.store.close()


def client(app, peer=DOOR):
    return httpx.AsyncClient(transport=httpx.ASGITransport(app=app, client=(peer, 40000)), base_url="http://relay")


async def test_the_door_path_admits_the_owner_only(door_app):
    app, p = door_app
    good = {"authorization": f"Bearer {p.keys[0].sign(claims())}", "x-forwarded-user": OWNER}
    async with client(app) as c:
        assert (await c.get("/api/v1/conversations", headers=good)).status_code == 200
        r = await c.get("/api/v1/conversations", headers={"authorization": good["authorization"]})
        assert r.status_code == 401 and r.headers["www-authenticate"].startswith("Bearer")
        assert (await c.get("/api/v1/conversations", headers={"x-forwarded-user": OWNER})).status_code == 401
        r = await c.get("/api/v1/conversations", headers={**good, "x-forwarded-user": "someone-else"})
        assert r.status_code == 403 and r.json()["error"]["code"] == "forbidden"
        stranger = p.keys[0].sign(claims(sub="someone-else"))
        r = await c.get("/api/v1/conversations", headers={"authorization": f"Bearer {stranger}",
                                                          "x-forwarded-user": "someone-else"})
        assert r.status_code == 403
        assert (await c.get("/healthz")).json() == {"ok": True}
    async with client(app, peer="10.253.92.1") as c:  # not the door
        r = await c.get("/api/v1/conversations", headers=good)
        assert r.status_code == 403 and r.json()["error"]["code"] == "not_through_door"


async def test_static_auth_still_serves_dev():
    class Req:
        headers = {"authorization": "Bearer parley-dev"}
        client = None

    assert (await StaticTokenAuth("parley-dev").authenticate(Req())).subject == "dev"


async def test_an_outage_serves_the_last_keys_and_backs_off():
    p = FakeProvider()
    now = [1000.0]
    v = verifier(p, clock=lambda: now[0], ttl=3600.0)
    token = p.keys[0].sign(claims())
    await v.verify(token)
    good_handler = p.handler
    attempts = []

    def down(request):
        attempts.append(request.url.path)
        raise httpx.ConnectError("no route")

    p.handler = down
    now[0] += 3601  # the cache ages out while the provider is down
    for _ in range(5):
        assert (await v.verify(token)).subject == OWNER  # the last keys, served on
    assert len(attempts) == 1  # one try, not one per request
    now[0] += 61
    await v.verify(token)
    assert len(attempts) == 2
    p.handler = good_handler
    now[0] += 61
    await v.verify(token)
    assert p.jwks_hits == 2


@pytest.mark.parametrize("name", ["exp", "nbf", "iat"])
async def test_non_finite_times_are_refused(name):
    p = FakeProvider()
    with pytest.raises(AuthError) as exc:
        await verifier(p).verify(p.keys[0].sign(claims(**{name: float("nan")})))
    assert exc.value.code == "invalid_token"
    with pytest.raises(AuthError):
        await verifier(p).verify(p.keys[0].sign(claims(**{name: float("inf")})))


@pytest.mark.parametrize("jwks_uri", ["http://id.example.ts.net/.well-known/jwks.json",
                                      "https://elsewhere.example/.well-known/jwks.json"])
async def test_keys_only_from_the_issuers_https_origin(jwks_uri):
    p = FakeProvider()
    base = p.handler

    def handler(request):
        if request.url.path == "/.well-known/openid-configuration":
            return httpx.Response(200, json={"issuer": ISSUER, "jwks_uri": jwks_uri})
        return base(request)

    p.handler = handler
    with pytest.raises(AuthError) as exc:
        await verifier(p).verify(p.keys[0].sign(claims()))
    assert exc.value.status == 503 and p.jwks_hits == 0
