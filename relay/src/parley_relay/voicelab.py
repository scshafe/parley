"""voice-lab's speech API, as a caller: requests, status, audio, and the webhook.

The contract is voice-lab ``docs/SPEECH_API.md``. The relay is a registered
caller: it posts a reply's text, follows the job by webhook (``speech.succeeded``,
Standard Webhooks signatures) with polling as a backstop, then fetches the
segments' durations and the joined audio.
"""

from __future__ import annotations

import base64
import binascii
import hashlib
import hmac
import time
from collections.abc import Awaitable, Callable, Mapping
from dataclasses import dataclass
from typing import Any

import httpx

TERMINAL_STATES = frozenset({"succeeded", "failed", "cancelled", "expired"})
WEBHOOK_TOLERANCE_SECONDS = 5 * 60

TokenProvider = Callable[[], Awaitable[str | None]]


class SpeechError(Exception):
    """A refusal or failure from the speech API. ``retryable`` says whether the
    same request may succeed later (a busy GPU, a full queue, a network error)."""

    def __init__(self, code: str, detail: str = "", *, status: int | None = None, retryable: bool = False,
                 retry_after: float | None = None) -> None:
        super().__init__(f"{code}: {detail}" if detail else code)
        self.code = code
        self.detail = detail
        self.status = status
        self.retryable = retryable
        self.retry_after = retry_after


def _refusal(resp: httpx.Response) -> SpeechError:
    code, detail = f"http_{resp.status_code}", ""
    try:
        body = resp.json()
    except ValueError:
        body = None
    if isinstance(body, dict):
        # voice-lab's ApiRefusal is {"error": "<stable code>", "detail": "..."}
        # (voice-lab src/cole_voice_lab/api/contracts.py). The P1 guesses,
        # {"code", "detail"} and {"error": {"code", "detail"}}, are read too.
        err = body.get("error")
        if isinstance(err, str) and err:
            code, detail = err, str(body.get("detail") or "")
        else:
            inner = err if isinstance(err, dict) else body
            code = str(inner.get("code") or code)
            detail = str(inner.get("detail") or "")
    retry_after = None
    if "retry-after" in resp.headers:
        try:
            retry_after = float(resp.headers["retry-after"])
        except ValueError:
            retry_after = None
    retryable = resp.status_code in (429, 502, 503, 504) and code not in ("voice_release_unavailable",)
    return SpeechError(code, detail, status=resp.status_code, retryable=retryable, retry_after=retry_after)


class SpeechClient:
    """A client of ``/api/v1/speech``. ``token`` provides the bearer (P2: a Pocket
    ID client-credentials token); it is never logged."""

    def __init__(self, base_url: str, *, token: TokenProvider | None = None,
                 transport: httpx.AsyncBaseTransport | None = None, timeout: float = 30.0) -> None:
        self._client = httpx.AsyncClient(base_url=base_url.rstrip("/"), transport=transport, timeout=timeout)
        self._token = token

    async def aclose(self) -> None:
        await self._client.aclose()

    async def _headers(self) -> dict[str, str]:
        headers = {"accept": "application/json"}
        if self._token is not None:
            try:
                tok = await self._token()
            except Exception as exc:  # a token provider's failure (oidc.TokenError) or a secret file's
                code = getattr(exc, "code", None) or "caller_token_unavailable"
                raise SpeechError("caller_token_unavailable", str(code),
                                  retryable=bool(getattr(exc, "retryable", False))) from exc
            if tok:
                headers["authorization"] = f"Bearer {tok}"
        return headers

    async def _request(self, method: str, path: str, **kw: Any) -> httpx.Response:
        """One request; a ``401`` with a token provider that can drop its token
        (client credentials) is retried exactly once with a fresh token."""
        invalidate = getattr(self._token, "invalidate", None)
        for attempt in (1, 2):
            try:
                resp = await self._client.request(method, path, headers=await self._headers(), **kw)
            except httpx.HTTPError as exc:
                raise SpeechError("network_error", type(exc).__name__, retryable=True) from exc
            if resp.status_code == 401 and attempt == 1 and callable(invalidate):
                invalidate()
                continue
            if resp.status_code >= 400:
                raise _refusal(resp)
            return resp
        raise AssertionError("unreachable")

    async def create(self, text: str, *, idempotency_key: str, client_ref: str | None = None,
                     callback_url: str | None = None) -> dict:
        """``POST /api/v1/speech``: ``202`` for a new job, ``200`` for a replay of
        the same key and body; both answer the job's status."""
        body: dict[str, Any] = {"text": text, "format": "wav", "idempotency_key": idempotency_key}
        if client_ref:
            body["client_ref"] = client_ref
        if callback_url:
            body["callback_url"] = callback_url
        resp = await self._request("POST", "/api/v1/speech", json=body)
        return resp.json()

    async def status(self, job_id: str) -> dict:
        return (await self._request("GET", f"/api/v1/speech/{job_id}")).json()

    async def audio(self, job_id: str) -> bytes:
        """The whole reply: the segments joined (``409 audio_not_ready`` before
        the job succeeds)."""
        return (await self._request("GET", f"/api/v1/speech/{job_id}/audio")).content

    async def segment_audio(self, job_id: str, index: int) -> bytes:
        return (await self._request("GET", f"/api/v1/speech/{job_id}/segments/{index}/audio")).content

    async def cancel(self, job_id: str) -> dict:
        return (await self._request("POST", f"/api/v1/speech/{job_id}/cancel")).json()


# --- Standard Webhooks ----------------------------------------------------------------


class WebhookError(Exception):
    pass


@dataclass(frozen=True)
class WebhookSecret:
    key: bytes

    @classmethod
    def parse(cls, secret: str) -> WebhookSecret:
        """``whsec_<base64>``, 24 to 64 bytes once decoded (SPEECH_API.md §4)."""
        secret = secret.strip()
        if not secret.startswith("whsec_"):
            raise ValueError("a webhook secret starts with whsec_")
        try:
            key = base64.b64decode(secret[len("whsec_") :], validate=True)
        except (binascii.Error, ValueError) as exc:
            raise ValueError("a webhook secret's key is base64") from exc
        if not 24 <= len(key) <= 64:
            raise ValueError("a webhook secret's key is 24 to 64 bytes")
        return cls(key)

    def sign(self, msg_id: str, timestamp: int, body: bytes) -> str:
        mac = hmac.new(self.key, f"{msg_id}.{timestamp}.".encode() + body, hashlib.sha256).digest()
        return "v1," + base64.b64encode(mac).decode()


def verify_webhook(secret: WebhookSecret, headers: Mapping[str, str], body: bytes, *, now: float | None = None) -> None:
    """Check a Standard Webhooks signature; raise :class:`WebhookError` if it does
    not hold. The timestamp must be within five minutes of the clock, and one of
    the space-separated ``v1,`` signatures must match in constant time."""
    lower = {k.lower(): v for k, v in headers.items()}
    msg_id = lower.get("webhook-id")
    ts = lower.get("webhook-timestamp")
    sigs = lower.get("webhook-signature")
    if not msg_id or not ts or not sigs:
        raise WebhookError("missing webhook headers")
    try:
        timestamp = int(ts)
    except ValueError as exc:
        raise WebhookError("bad webhook timestamp") from exc
    clock = time.time() if now is None else now
    if abs(clock - timestamp) > WEBHOOK_TOLERANCE_SECONDS:
        raise WebhookError("webhook timestamp out of tolerance")
    expected = secret.sign(msg_id, timestamp, body).encode()
    for candidate in sigs.split():
        if candidate.startswith("v1,") and hmac.compare_digest(candidate.encode(), expected):
            return
    raise WebhookError("no matching webhook signature")


def load_secret_file(path: str) -> WebhookSecret:
    with open(path, encoding="utf-8") as fh:
        return WebhookSecret.parse(fh.read())
