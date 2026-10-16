"""The relay's own Pocket ID identity: an OAuth 2.0 client-credentials token,
the bearer it presents to voice-lab's speech API as the caller ``parley``.

The client (``parley-relay``) is confidential; its secret is a file read when a
token is fetched (``client_secret_basic`` to the issuer's token endpoint, found
in its discovery document). A token is reused until 60 seconds before it
expires; :meth:`ClientCredentials.invalidate` drops it, so a ``401`` from
voice-lab is answered with exactly one fresh token. Neither the secret nor a
token is ever logged.
"""

from __future__ import annotations

import asyncio
import base64
import json
import logging
import time
from collections.abc import Callable
from urllib.parse import quote

import httpx

from .auth import same_origin_https
from .secretfiles import SecretFile, SecretFileError

log = logging.getLogger("parley.oidc")

EXPIRY_MARGIN_SECONDS = 60.0
DEFAULT_LIFETIME_SECONDS = 300.0


class TokenError(Exception):
    """No token could be had. ``retryable`` says whether a later try may work
    (the provider unreachable or busy) or not (no secret, a refused client)."""

    def __init__(self, code: str, detail: str = "", *, retryable: bool = False) -> None:
        super().__init__(f"{code}: {detail}" if detail else code)
        self.code = code
        self.detail = detail
        self.retryable = retryable


def _jwt_exp(token: str) -> float | None:
    """A JWT's ``exp`` claim, read without verifying anything (the token is
    ours, from the provider over TLS; this only times its renewal)."""
    try:
        part = token.split(".")[1]
        claims = json.loads(base64.urlsafe_b64decode(part + "=" * (-len(part) % 4)))
        exp = claims.get("exp")
        return float(exp) if isinstance(exp, int | float) and not isinstance(exp, bool) else None
    except (IndexError, ValueError, AttributeError):
        return None


class ClientCredentials:
    """A token provider: ``await provider()`` answers a bearer token."""

    def __init__(self, issuer: str, client_id: str, secret: SecretFile[str], *, scope: str | None = None,
                 transport: httpx.AsyncBaseTransport | None = None, clock: Callable[[], float] = time.time,
                 margin: float = EXPIRY_MARGIN_SECONDS) -> None:
        if not issuer or not client_id:
            raise ValueError("an issuer and a client id are required")
        self.issuer = issuer.rstrip("/")
        self.client_id = client_id
        self._secret = secret
        self._scope = scope
        self._client = httpx.AsyncClient(transport=transport, timeout=15.0)
        self._clock = clock
        self._margin = margin
        self._token: str | None = None
        self._renew_at = 0.0
        self._token_endpoint: str | None = None
        self._lock = asyncio.Lock()
        self.fetches = 0  # tests and the start-up line

    async def aclose(self) -> None:
        await self._client.aclose()

    def invalidate(self) -> None:
        self._token = None
        self._renew_at = 0.0

    async def __call__(self) -> str:
        async with self._lock:
            if self._token is not None and self._clock() < self._renew_at:
                return self._token
            token, lifetime_end = await self._fetch()
            self._token = token
            self._renew_at = lifetime_end - self._margin
            return token

    async def _endpoint(self) -> str:
        if self._token_endpoint is None:
            try:
                resp = await self._client.get(f"{self.issuer}/.well-known/openid-configuration")
            except httpx.HTTPError as exc:
                raise TokenError("provider_unreachable", type(exc).__name__, retryable=True) from exc
            if resp.status_code != 200:
                raise TokenError("discovery_failed", f"HTTP {resp.status_code}", retryable=resp.status_code >= 500)
            try:
                disco = resp.json()
                endpoint = disco["token_endpoint"]
            except (ValueError, KeyError, TypeError) as exc:
                raise TokenError("discovery_failed", "no token endpoint") from exc
            if not same_origin_https(endpoint, self.issuer):
                # Never send the client secret anywhere but the issuer's own https origin.
                raise TokenError("discovery_failed", "the token endpoint is not https on the issuer's origin")
            self._token_endpoint = endpoint
        return self._token_endpoint

    async def _fetch(self) -> tuple[str, float]:
        try:
            secret = self._secret.require()
        except SecretFileError as exc:
            raise TokenError("client_secret_unavailable", str(exc)) from exc
        endpoint = await self._endpoint()
        # client_secret_basic (RFC 6749 §2.3.1): each part form-encoded, then Basic.
        basic = base64.b64encode(f"{quote(self.client_id, safe='')}:{quote(secret, safe='')}".encode()).decode()
        form = {"grant_type": "client_credentials"}
        if self._scope:
            form["scope"] = self._scope
        started = self._clock()
        try:
            resp = await self._client.post(endpoint, data=form, headers={"authorization": f"Basic {basic}",
                                                                          "accept": "application/json"})
        except httpx.HTTPError as exc:
            raise TokenError("provider_unreachable", type(exc).__name__, retryable=True) from exc
        self.fetches += 1
        if resp.status_code != 200:
            code = "token_refused"
            try:
                code = str(resp.json().get("error") or code)
            except (ValueError, AttributeError):
                pass
            log.warning("voice-lab caller token refused by the provider: HTTP %d %s", resp.status_code, code)
            raise TokenError(code, f"HTTP {resp.status_code}", retryable=resp.status_code >= 500 or resp.status_code == 429)
        try:
            body = resp.json()
            token = body["access_token"]
        except (ValueError, KeyError, TypeError) as exc:
            raise TokenError("token_bad_reply", "no access_token") from exc
        if not isinstance(token, str) or not token:
            raise TokenError("token_bad_reply", "no access_token")
        expires_in = body.get("expires_in")
        if isinstance(expires_in, int | float) and not isinstance(expires_in, bool) and expires_in > 0:
            end = started + float(expires_in)
        else:
            end = _jwt_exp(token) or started + DEFAULT_LIFETIME_SECONDS
        return token, end
