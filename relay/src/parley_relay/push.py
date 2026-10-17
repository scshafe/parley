"""Telling the phone a reply is ready.

A push carries only ids and a fixed alert, never reply text: pushes pass
through Apple. :class:`APNsSender` sends it to every registered device over
HTTP/2 with a token-based (``.p8``) provider token; without the key it is off,
says so once, and the relay works on (the app follows its event stream). A
push never fails a turn.
"""

from __future__ import annotations

import base64
import json
import logging
import re
import time
from collections.abc import Callable
from dataclasses import dataclass, field
from typing import Any, Protocol

import httpx
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature

from .secretfiles import SecretFile, SecretFileError

log = logging.getLogger("parley.push")


class _DeviceTokenRedaction(logging.Filter):
    """httpx logs each request's URL at INFO, and an APNs URL ends in the
    device token. The relay's own lines name a device by its id; this keeps the
    token out of httpx's line too."""

    _token = re.compile(r"(/3/device/)[^\s\"']+")

    def filter(self, record: logging.LogRecord) -> bool:
        message = record.getMessage()
        if "/3/device/" in message:
            record.msg, record.args = self._token.sub(r"\1<device token>", message), ()
        return True


logging.getLogger("httpx").addFilter(_DeviceTokenRedaction())

REPLY_READY_ALERT = "Reply ready"

APNS_HOSTS = {
    "sandbox": "https://api.sandbox.push.apple.com",
    "production": "https://api.push.apple.com",
}
# Apple: a provider token is refused if older than an hour and may not be
# renewed more often than every 20 minutes.
PROVIDER_TOKEN_RENEW_SECONDS = 50 * 60
PUSH_EXPIRATION_SECONDS = 24 * 3600
# Answers that mean the device token is no good: forget the device.
# Only these forget a device. BadDeviceToken is not one: Apple also answers it
# for a token sent to the wrong environment's host.
PRUNE_REASONS = frozenset({"Unregistered"})


def reply_ready_payload(conversation_id: str, turn_id: str) -> dict:
    return {
        "aps": {"alert": REPLY_READY_ALERT, "sound": "default"},
        "conversation_id": conversation_id,
        "turn_id": turn_id,
    }


class PushSender(Protocol):
    async def reply_ready(self, conversation_id: str, turn_id: str) -> None: ...


class NoopPushSender:
    enabled = False

    async def reply_ready(self, conversation_id: str, turn_id: str) -> None:
        return None

    def describe(self) -> str:
        return "off"


@dataclass
class RecordingPushSender:
    """Records each payload it would send, for tests and ``--dev``."""

    sent: list[dict] = field(default_factory=list)
    enabled = True

    async def reply_ready(self, conversation_id: str, turn_id: str) -> None:
        self.sent.append(reply_ready_payload(conversation_id, turn_id))

    def describe(self) -> str:
        return "recorded (dev)"


def _b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def _load_p8(text: str) -> ec.EllipticCurvePrivateKey:
    key = serialization.load_pem_private_key(text.encode(), password=None)
    if not isinstance(key, ec.EllipticCurvePrivateKey) or key.curve.name != "secp256r1":
        raise ValueError("an APNs key is a P-256 EC private key")
    return key


def provider_token(key: ec.EllipticCurvePrivateKey, *, key_id: str, team_id: str, issued_at: int) -> str:
    """An APNs provider token: an ES256 JWT, ``{alg, kid}`` and ``{iss, iat}``."""
    header = _b64url(json.dumps({"alg": "ES256", "kid": key_id}, separators=(",", ":")).encode())
    claims = _b64url(json.dumps({"iss": team_id, "iat": issued_at}, separators=(",", ":")).encode())
    signing_input = f"{header}.{claims}".encode()
    r, s = decode_dss_signature(key.sign(signing_input, ec.ECDSA(hashes.SHA256())))
    return f"{header}.{claims}.{_b64url(r.to_bytes(32, 'big') + s.to_bytes(32, 'big'))}"


class APNsSender:
    """APNs over HTTP/2 to every device in the store.

    On: a key id, a team id and the ``.p8`` file. The file is read on use, so
    a key placed later turns push on without a restart. Each device's
    registered environment picks the host (``sandbox`` for a debug build,
    ``production`` for a release). 410 (``Unregistered``) forgets the
    device; ``BadDeviceToken`` tries the other environment's host once and
    keeps the device; a refused provider token is renewed once per push."""

    def __init__(self, store: Any, *, key_file: str | None, key_id: str | None, team_id: str | None,
                 topic: str = "com.scshafe.parley", hosts: dict[str, str] | None = None,
                 clock: Callable[[], float] = time.time, http1: bool = False,
                 transport_factory: Callable[[str], httpx.AsyncBaseTransport] | None = None) -> None:
        self.store = store
        self.key_id = key_id or None
        self.team_id = team_id or None
        self.topic = topic
        self.hosts = dict(hosts or APNS_HOSTS)
        self._key = SecretFile(key_file, "PARLEY_APNS_KEY_FILE", _load_p8) if key_file else None  # type: ignore[arg-type]
        self._clock = clock
        self._http1 = http1
        self._transport_factory = transport_factory
        self._clients: dict[str, httpx.AsyncClient] = {}
        self._token: tuple[int, ec.EllipticCurvePrivateKey, str] | None = None  # (issued_at, key, jwt)
        self._last_state: str | None = None
        self.sent = 0

    @property
    def configured(self) -> bool:
        return bool(self.key_id and self.team_id and self._key)

    def describe(self) -> str:
        if not self.configured:
            return "off (no APNs key id, team id or key file configured)"
        return f"APNs, topic {self.topic} ({'key file present' if self._key.exists() else 'key file missing'})"  # type: ignore[union-attr]

    @property
    def enabled(self) -> bool:
        """Whether a push would be sent now (the key is configured and its file
        is usable)."""
        return self._signing_key() is not None

    def _note(self, state: str, message: str, *args: object) -> None:
        """Log a change of push state once, not on every turn."""
        if state != self._last_state:
            self._last_state = state
            (log.info if state == "on" else log.warning)(message, *args)

    def _signing_key(self) -> ec.EllipticCurvePrivateKey | None:
        if not self.configured:
            self._note("unconfigured", "push off: no APNs key id, team id or key file is configured")
            return None
        try:
            key = self._key.get()  # type: ignore[union-attr]
        except SecretFileError as exc:
            self._note("bad-key", "push off: %s", exc)
            return None
        if key is None:
            self._note("no-key", "push off: the APNs key file is not there yet; the app follows its event stream")
            return None
        self._note("on", "push on: APNs key %s", self.key_id)
        return key

    def _provider_token(self, key: ec.EllipticCurvePrivateKey, *, renew: bool = False) -> str:
        now = int(self._clock())
        if (renew or self._token is None or self._token[1] is not key
                or now - self._token[0] >= PROVIDER_TOKEN_RENEW_SECONDS):
            self._token = (now, key, provider_token(key, key_id=self.key_id, team_id=self.team_id,  # type: ignore[arg-type]
                                                   issued_at=now))
        return self._token[2]

    def _client(self, environment: str) -> httpx.AsyncClient:
        env = environment if environment in self.hosts else "sandbox"
        if env not in self._clients:
            transport = self._transport_factory(env) if self._transport_factory else None
            self._clients[env] = httpx.AsyncClient(base_url=self.hosts[env], http1=self._http1, http2=True,
                                                   transport=transport, timeout=15.0)
        return self._clients[env]

    async def aclose(self) -> None:
        for client in self._clients.values():
            await client.aclose()
        self._clients.clear()

    async def reply_ready(self, conversation_id: str, turn_id: str) -> None:
        try:
            key = self._signing_key()
            if key is None:
                return
            body = json.dumps(reply_ready_payload(conversation_id, turn_id), separators=(",", ":")).encode()
            push = _Push(key, body, turn_id)
            for device in self.store.devices():
                try:
                    await self._send(push, device)
                except Exception:  # noqa: BLE001 - one bad device must not stop the others
                    log.exception("push to device %s for turn %s failed", device.get("id"), turn_id)
        except Exception:  # noqa: BLE001 - a push never fails a turn
            log.exception("push for turn %s failed", turn_id)

    async def _post(self, push: _Push, environment: str, token: str) -> tuple[int, str, httpx.Response]:
        """One POST; a refused provider token is renewed and the POST retried,
        at most once per push (not once per device)."""
        while True:
            headers = {
                "authorization": f"bearer {self._provider_token(push.key, renew=push.renew_now)}",
                "apns-topic": self.topic,
                "apns-push-type": "alert",
                "apns-priority": "10",
                "apns-expiration": str(int(self._clock()) + PUSH_EXPIRATION_SECONDS),
                "apns-collapse-id": push.turn_id,
                "content-type": "application/json",
            }
            push.renew_now = False
            resp = await self._client(environment).post(f"/3/device/{token}", content=push.body, headers=headers)
            reason = ""
            if resp.status_code != 200:
                try:
                    reason = str(resp.json().get("reason") or "")
                except (ValueError, AttributeError):
                    reason = ""
            if (resp.status_code == 403 and reason in ("ExpiredProviderToken", "InvalidProviderToken")
                    and not push.renewed):
                push.renewed = push.renew_now = True
                continue
            return resp.status_code, reason, resp

    async def _send(self, push: _Push, device: dict) -> None:
        did, env = device["id"], device["environment"]
        try:
            status, reason, resp = await self._post(push, env, device["token"])
            if status == 400 and reason == "BadDeviceToken":
                # Apple's answer for a token sent to the other environment's host (a
                # debug build registered as production, or the reverse): try that
                # host once, and keep the device either way.
                other = "production" if env == "sandbox" else "sandbox"
                log.warning("push to device %s: BadDeviceToken on %s, trying %s once (an environment mismatch?)",
                            did, env, other)
                status2, reason2, resp2 = await self._post(push, other, device["token"])
                if status2 == 200:
                    self.store.register_device(device["token"], other)
                    log.info("device %s is a %s device: its environment is updated", did, other)
                    env, status, reason, resp = other, status2, reason2, resp2
                elif status2 not in (400, 410):
                    status, reason = status2, reason2
        except httpx.HTTPError as exc:
            log.warning("push to device %s for turn %s: %s", did, push.turn_id, type(exc).__name__)
            return
        self.store.record_push(did, status)
        if status == 200:
            self.sent += 1
            log.info("push sent to device %s for turn %s (apns-id %s)", did, push.turn_id,
                     resp.headers.get("apns-id", "-"))
        elif status == 410 or reason in PRUNE_REASONS:
            self.store.delete_device(did)
            log.info("push to device %s refused (%d %s): device forgotten", did, status, reason or "-")
        else:
            log.warning("push to device %s for turn %s refused: %d %s", did, push.turn_id, status, reason or "-")


@dataclass
class _Push:
    """One reply-ready push, sent to every device."""

    key: ec.EllipticCurvePrivateKey
    body: bytes
    turn_id: str
    renewed: bool = False  # the provider token was renewed once already for this push
    renew_now: bool = False
