"""Settings and wiring: the relay for real, or ``--dev`` with every outside
service faked in-process (no network beyond the relay's own listening socket)."""

from __future__ import annotations

import logging
import os
from dataclasses import dataclass, field
from pathlib import Path
from urllib.parse import urlsplit

import httpx
from starlette.applications import Starlette

from .agent import AgentAdapter, AgentError, FakeAgent, OpenClawAgent
from .api import build_app
from .auth import DoorAuth, JwksSource, JwtVerifier
from .fake_voicelab import FakeVoiceLab
from .oidc import ClientCredentials
from .pipeline import Pipeline, PipelineSettings
from .push import APNsSender, RecordingPushSender
from .secretfiles import SecretFile, SecretFileError
from .store import Store
from .voicelab import SpeechClient, TokenProvider, WebhookSecret

log = logging.getLogger("parley")

# --dev's one bearer: a public placeholder for local development and the app's
# UI tests (CI), not a secret. A dev relay listens only on loopback (cli.py).
DEV_TOKEN = "parley-dev"
DEV_PUBLIC_URL = "https://parley.example.ts.net"


class ConfigError(Exception):
    pass


def _list(value: str | None) -> tuple[str, ...]:
    return tuple(v.strip() for v in (value or "").split(",") if v.strip())


@dataclass
class Settings:
    """From the environment (``PARLEY_*``); every secret is a file path, read
    when it is needed (relay/README.md, "Configuration")."""

    dev: bool = False
    data_dir: Path = Path("state")
    # The app's sign-in (real mode): the bearer's issuer and audiences, the owner,
    # and the door's upstream address.
    oidc_issuer: str | None = None
    oidc_audiences: tuple[str, ...] = ("parley-ios",)
    owner_subject: str | None = None
    trusted_proxies: tuple[str, ...] = ()
    agent: str = "openclaw"  # PARLEY_AGENT: openclaw | fake
    openclaw_url: str | None = None
    openclaw_token_file: str | None = None
    openclaw_agent_id: str | None = None
    voicelab_url: str | None = None
    voicelab_client_id: str | None = None  # client credentials (P2)
    voicelab_client_secret_file: str | None = None
    voicelab_token_file: str | None = None  # a static bearer instead (testing by hand)
    webhook_secret_file: str | None = None
    public_url: str | None = None  # the relay's tailnet URL, for voice-lab's callback
    # APNs (optional): off unless the key id, the team id and the key file are set.
    apns_key_file: str | None = None
    apns_key_id: str | None = None
    apns_team_id: str | None = None
    apns_topic: str = "com.scshafe.parley"
    apns_env: str = "sandbox"  # for a device that registers without an environment
    poll_interval: float = 15.0
    max_sentence_chars: int | None = None
    fake_agent_delay: float = 1.0
    fake_speech_speed: float = 0.3
    extra: dict = field(default_factory=dict)

    @classmethod
    def from_env(cls, *, dev: bool = False, env: dict[str, str] | None = None) -> Settings:
        e = dict(os.environ if env is None else env)
        msc = e.get("PARLEY_MAX_SENTENCE_CHARS")
        return cls(
            dev=dev,
            data_dir=Path(e.get("PARLEY_DATA_DIR") or (".parley-dev" if dev else "state")),
            oidc_issuer=e.get("PARLEY_OIDC_ISSUER") or None,
            oidc_audiences=_list(e.get("PARLEY_OIDC_AUDIENCE")) or ("parley-ios",),
            owner_subject=e.get("PARLEY_OWNER_SUBJECT") or None,
            trusted_proxies=_list(e.get("PARLEY_TRUSTED_PROXY")),
            agent=e.get("PARLEY_AGENT", "fake" if dev else "openclaw"),
            openclaw_url=e.get("PARLEY_OPENCLAW_URL") or None,
            openclaw_token_file=e.get("PARLEY_OPENCLAW_TOKEN_FILE") or None,
            openclaw_agent_id=e.get("PARLEY_OPENCLAW_AGENT_ID") or None,
            voicelab_url=e.get("PARLEY_VOICELAB_URL") or None,
            voicelab_client_id=e.get("PARLEY_VOICELAB_CLIENT_ID") or None,
            voicelab_client_secret_file=e.get("PARLEY_VOICELAB_CLIENT_SECRET_FILE") or None,
            voicelab_token_file=e.get("PARLEY_VOICELAB_TOKEN_FILE") or None,
            webhook_secret_file=e.get("PARLEY_WEBHOOK_SECRET_FILE") or None,
            public_url=e.get("PARLEY_PUBLIC_URL") or None,
            apns_key_file=e.get("PARLEY_APNS_KEY_FILE") or None,
            apns_key_id=e.get("PARLEY_APNS_KEY_ID") or None,
            apns_team_id=e.get("PARLEY_APNS_TEAM_ID") or None,
            apns_topic=e.get("PARLEY_APNS_TOPIC") or "com.scshafe.parley",
            apns_env=e.get("PARLEY_APNS_ENV") or "sandbox",
            poll_interval=float(e.get("PARLEY_POLL_INTERVAL", "1.0" if dev else "15")),
            max_sentence_chars=int(msc) if msc else None,
        )


@dataclass
class Relay:
    app: Starlette
    store: Store
    pipeline: Pipeline
    push: object
    fake_voicelab: FakeVoiceLab | None = None
    agent: AgentAdapter | None = None


def build(settings: Settings) -> Relay:
    if settings.dev:
        return _build_dev(settings)
    return _build_real(settings)


def _build_dev(s: Settings) -> Relay:
    store = Store(s.data_dir)
    secret = WebhookSecret(os.urandom(32))
    callback = f"{DEV_PUBLIC_URL}/hooks/voice-lab"
    holder: dict[str, Starlette] = {}

    async def deliver(url: str, headers: dict[str, str], body: bytes) -> int:
        # The fake's webhook goes straight into the relay app, in-process.
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=holder["app"]), base_url=DEV_PUBLIC_URL) as c:
            resp = await c.post(urlsplit(url).path, headers=headers, content=body)
            return resp.status_code

    fake = FakeVoiceLab(token="fake-voice-lab-token", secret=secret, deliver=deliver, speed=s.fake_speech_speed,
                        webhook_urls=(callback,), tailnet_suffix="example.ts.net",
                        max_sentence_chars=s.max_sentence_chars)

    async def fake_token() -> str:
        return "fake-voice-lab-token"

    speech = SpeechClient("http://voice-lab.invalid", token=fake_token, transport=httpx.ASGITransport(app=fake.app))
    agent: AgentAdapter = FakeAgent(delay=s.fake_agent_delay) if s.agent == "fake" else _openclaw(s)
    push = RecordingPushSender()
    pipeline = Pipeline(store, agent, speech, push, PipelineSettings(
        callback_url=callback, poll_interval=s.poll_interval, max_sentence_chars=s.max_sentence_chars,
        backoff=0.5, backoff_cap=5.0))
    app = build_app(store=store, pipeline=pipeline, token=DEV_TOKEN, webhook_secret=secret,
                    on_shutdown=speech.aclose)
    holder["app"] = app
    return Relay(app, store, pipeline, push, fake, agent)


def _openclaw(s: Settings) -> OpenClawAgent:
    if not s.openclaw_url:
        raise ConfigError("PARLEY_OPENCLAW_URL is not set")
    if not s.openclaw_token_file:
        raise ConfigError("PARLEY_OPENCLAW_TOKEN_FILE is not set")
    gateway = SecretFile(s.openclaw_token_file, "PARLEY_OPENCLAW_TOKEN_FILE")

    async def token() -> str:
        # Read on use: a placed or rotated gateway password needs no restart.
        try:
            value = gateway.get()
        except SecretFileError as exc:
            raise AgentError("agent_unconfigured", str(exc)) from exc
        if value is None:
            raise AgentError("agent_unconfigured", "PARLEY_OPENCLAW_TOKEN_FILE: the configured file does not exist")
        return value

    return OpenClawAgent(s.openclaw_url, token=token, agent_id=s.openclaw_agent_id)


def _file_state(path: str | None) -> str:
    if not path:
        return "not configured"
    return "file present" if os.path.exists(path) else "file missing"


def _build_real(s: Settings) -> Relay:
    missing = [name for name, value in (("PARLEY_OIDC_ISSUER", s.oidc_issuer), ("PARLEY_OWNER_SUBJECT", s.owner_subject),
                                        ("PARLEY_VOICELAB_URL", s.voicelab_url)) if not value]
    if missing:
        raise ConfigError(f"set {', '.join(missing)}: the relay refuses to start without them")
    closers: list = []

    # The app: a Pocket ID bearer for the owner, through the door.
    jwks = JwksSource(s.oidc_issuer)  # type: ignore[arg-type]
    closers.append(jwks.aclose)
    auth = DoorAuth(JwtVerifier(jwks, issuer=s.oidc_issuer, audiences=s.oidc_audiences,  # type: ignore[arg-type]
                                subjects=(s.owner_subject,)),  # type: ignore[arg-type]
                    owner_subject=s.owner_subject, trusted_proxies=s.trusted_proxies)  # type: ignore[arg-type]

    # voice-lab: the caller's bearer, and its webhook.
    speech_token: TokenProvider | None = None
    if s.voicelab_client_id:
        if not s.voicelab_client_secret_file:
            raise ConfigError("PARLEY_VOICELAB_CLIENT_ID needs PARLEY_VOICELAB_CLIENT_SECRET_FILE")
        provider = ClientCredentials(s.oidc_issuer, s.voicelab_client_id,  # type: ignore[arg-type]
                                     SecretFile(s.voicelab_client_secret_file, "PARLEY_VOICELAB_CLIENT_SECRET_FILE"))
        closers.append(provider.aclose)
        speech_token = provider
        speech_note = f"voice-lab caller (client credentials, {_file_state(s.voicelab_client_secret_file)})"
    elif s.voicelab_token_file:
        static = SecretFile(s.voicelab_token_file, "PARLEY_VOICELAB_TOKEN_FILE")

        async def static_token() -> str | None:
            return static.require()

        speech_token = static_token
        speech_note = f"voice-lab (static bearer, {_file_state(s.voicelab_token_file)})"
    else:
        speech_note = "voice-lab (no caller credential)"
    speech = SpeechClient(s.voicelab_url, token=speech_token)  # type: ignore[arg-type]
    closers.append(speech.aclose)
    webhook = (SecretFile(s.webhook_secret_file, "PARLEY_WEBHOOK_SECRET_FILE", WebhookSecret.parse)
               if s.webhook_secret_file else None)
    callback = f"{s.public_url.rstrip('/')}/hooks/voice-lab" if s.public_url and webhook else None

    agent: AgentAdapter = FakeAgent() if s.agent == "fake" else _openclaw(s)
    if isinstance(agent, OpenClawAgent):
        closers.append(agent.aclose)
    if s.apns_env == "development":  # the entitlement's word for the sandbox, as the API accepts it
        s.apns_env = "sandbox"
    if s.apns_env not in ("sandbox", "production"):
        raise ConfigError("PARLEY_APNS_ENV is sandbox (or development) or production")
    store = Store(s.data_dir)
    push = APNsSender(store, key_file=s.apns_key_file, key_id=s.apns_key_id, team_id=s.apns_team_id,
                      topic=s.apns_topic)
    closers.append(push.aclose)
    pipeline = Pipeline(store, agent, speech, push, PipelineSettings(
        callback_url=callback, poll_interval=s.poll_interval, max_sentence_chars=s.max_sentence_chars))

    async def shutdown() -> None:
        for close in closers:
            await close()

    app = build_app(store=store, pipeline=pipeline, auth=auth, webhook_secret=webhook.get if webhook else None,
                    default_environment=s.apns_env, on_shutdown=shutdown)
    agent_note = ("fake" if s.agent == "fake"
                  else f"openclaw ({_file_state(s.openclaw_token_file)}{', agent ' + s.openclaw_agent_id if s.openclaw_agent_id else ''})")
    webhook_note = f"on ({_file_state(s.webhook_secret_file)})" if callback else "off (polling only)"
    log.info("parley-relay: app auth: %s; agent: %s; speech: %s; webhook: %s; push: %s",
             auth.describe(), agent_note, speech_note, webhook_note, push.describe())
    return Relay(app, store, pipeline, push, None, agent)
