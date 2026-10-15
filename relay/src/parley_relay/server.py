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

from .agent import AgentAdapter, FakeAgent, OpenClawAgent
from .api import build_app
from .fake_voicelab import FakeVoiceLab
from .pipeline import Pipeline, PipelineSettings
from .push import RecordingPushSender
from .store import Store
from .voicelab import SpeechClient, WebhookSecret, load_secret_file

log = logging.getLogger("parley")

DEV_TOKEN = "parley-dev"  # a public placeholder for local development, not a secret
DEV_PUBLIC_URL = "https://parley.example.ts.net"


class ConfigError(Exception):
    pass


def _read_secret(path: str | None, what: str) -> str:
    if not path:
        raise ConfigError(f"{what}: no file configured")
    try:
        value = Path(path).read_text("utf-8").strip()
    except OSError as exc:
        raise ConfigError(f"{what}: cannot read the configured file") from exc
    if not value:
        raise ConfigError(f"{what}: the configured file is empty")
    return value


@dataclass
class Settings:
    """From the environment (``PARLEY_*``); every secret is a file path."""

    dev: bool = False
    data_dir: Path = Path("state")
    token: str | None = None  # PARLEY_TOKEN_FILE (or PARLEY_TOKEN), P1's single bearer
    agent: str = "openclaw"  # PARLEY_AGENT: openclaw | fake
    openclaw_url: str | None = None
    openclaw_token_file: str | None = None
    openclaw_agent_id: str | None = None
    voicelab_url: str | None = None
    voicelab_token_file: str | None = None
    webhook_secret_file: str | None = None
    public_url: str | None = None  # the relay's tailnet URL, for voice-lab's callback
    poll_interval: float = 15.0
    max_sentence_chars: int | None = None
    fake_agent_delay: float = 1.0
    fake_speech_speed: float = 0.3
    extra: dict = field(default_factory=dict)

    @classmethod
    def from_env(cls, *, dev: bool = False, env: dict[str, str] | None = None) -> Settings:
        e = dict(os.environ if env is None else env)
        token = None
        if e.get("PARLEY_TOKEN_FILE"):
            token = _read_secret(e["PARLEY_TOKEN_FILE"], "PARLEY_TOKEN_FILE")
        elif e.get("PARLEY_TOKEN"):
            token = e["PARLEY_TOKEN"]
        msc = e.get("PARLEY_MAX_SENTENCE_CHARS")
        return cls(
            dev=dev,
            data_dir=Path(e.get("PARLEY_DATA_DIR") or (".parley-dev" if dev else "state")),
            token=token,
            agent=e.get("PARLEY_AGENT", "fake" if dev else "openclaw"),
            openclaw_url=e.get("PARLEY_OPENCLAW_URL"),
            openclaw_token_file=e.get("PARLEY_OPENCLAW_TOKEN_FILE"),
            openclaw_agent_id=e.get("PARLEY_OPENCLAW_AGENT_ID") or None,
            voicelab_url=e.get("PARLEY_VOICELAB_URL"),
            voicelab_token_file=e.get("PARLEY_VOICELAB_TOKEN_FILE"),
            webhook_secret_file=e.get("PARLEY_WEBHOOK_SECRET_FILE"),
            public_url=e.get("PARLEY_PUBLIC_URL"),
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
    token = s.token or DEV_TOKEN
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
    app = build_app(store=store, pipeline=pipeline, token=token, webhook_secret=secret,
                    on_shutdown=speech.aclose)
    holder["app"] = app
    return Relay(app, store, pipeline, push, fake, agent)


def _openclaw(s: Settings) -> OpenClawAgent:
    if not s.openclaw_url:
        raise ConfigError("PARLEY_OPENCLAW_URL is not set")
    gateway_token = _read_secret(s.openclaw_token_file, "PARLEY_OPENCLAW_TOKEN_FILE")

    async def token() -> str:
        return gateway_token

    return OpenClawAgent(s.openclaw_url, token=token, agent_id=s.openclaw_agent_id)


def _build_real(s: Settings) -> Relay:
    if not s.token:
        raise ConfigError("set PARLEY_TOKEN_FILE: the relay refuses to start without a bearer token")
    if not s.voicelab_url:
        raise ConfigError("PARLEY_VOICELAB_URL is not set")
    store = Store(s.data_dir)
    secret = load_secret_file(s.webhook_secret_file) if s.webhook_secret_file else None
    callback = f"{s.public_url.rstrip('/')}/hooks/voice-lab" if s.public_url and secret else None
    vl_token = _read_secret(s.voicelab_token_file, "PARLEY_VOICELAB_TOKEN_FILE") if s.voicelab_token_file else None

    async def speech_token() -> str | None:
        # P1: a static bearer from a file. P2: a Pocket ID client-credentials token.
        return vl_token

    speech = SpeechClient(s.voicelab_url, token=speech_token)
    agent: AgentAdapter = FakeAgent() if s.agent == "fake" else _openclaw(s)
    push = RecordingPushSender()  # APNs comes in P2
    pipeline = Pipeline(store, agent, speech, push, PipelineSettings(
        callback_url=callback, poll_interval=s.poll_interval, max_sentence_chars=s.max_sentence_chars))
    app = build_app(store=store, pipeline=pipeline, token=s.token, webhook_secret=secret, on_shutdown=speech.aclose)
    return Relay(app, store, pipeline, push, None, agent)
