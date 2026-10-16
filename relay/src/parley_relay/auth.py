"""Who may use the relay's API.

- ``--dev``: one static bearer (the public placeholder ``parley-dev``).
- Real mode, behind the Pocket ID door (deploy/stack/compose.yaml): the app
  signs in with Pocket ID's public client ``parley-ios`` and sends its access
  token as ``Authorization: Bearer``. The door (oauth2-proxy) verifies it,
  passes it through unchanged and sets ``X-Forwarded-User`` to its subject,
  after stripping any copy the caller sent. The relay then checks, itself:

  1. the request came from the door (its peer address is the door's
     upstream address, ``PARLEY_TRUSTED_PROXY``), when that is configured;
  2. the bearer is a JWT signed by one of the issuer's published keys (JWKS,
     RS256 or ES256), from the expected issuer, for the expected audience,
     within its lifetime;
  3. its subject is the owner (``PARLEY_OWNER_SUBJECT``), and the door's
     ``X-Forwarded-User`` names the same subject.

Nothing here logs or returns a token.
"""

from __future__ import annotations

import asyncio
import base64
import binascii
import hmac
import json
import logging
import time
from collections.abc import Callable, Iterable, Mapping
from dataclasses import dataclass
from typing import Any, Protocol

import httpx
from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import ec, padding, rsa
from cryptography.hazmat.primitives.asymmetric.utils import encode_dss_signature

log = logging.getLogger("parley.auth")

MAX_TOKEN_BYTES = 16 * 1024
MAX_JWKS_BYTES = 256 * 1024
MIN_RSA_BITS = 2048
LEEWAY_SECONDS = 60


class AuthError(Exception):
    """A request the relay refuses. ``status`` is the HTTP answer (401: no or a
    bad credential; 403: a good one that may not use the relay). The message
    never quotes a token."""

    def __init__(self, code: str, detail: str, *, status: int = 401) -> None:
        super().__init__(detail)
        self.code = code
        self.detail = detail
        self.status = status


@dataclass(frozen=True)
class Principal:
    subject: str


class RequestLike(Protocol):
    @property
    def headers(self) -> Mapping[str, str]: ...

    @property
    def client(self) -> Any: ...


class Authenticator(Protocol):
    async def authenticate(self, request: RequestLike) -> Principal: ...

    def describe(self) -> str: ...


class StaticTokenAuth:
    """One fixed bearer, compared in constant time (``--dev``)."""

    def __init__(self, token: str) -> None:
        if not token:
            raise ValueError("a static bearer token is required")
        self._expected = f"Bearer {token}".encode()

    async def authenticate(self, request: RequestLike) -> Principal:
        if not hmac.compare_digest(request.headers.get("authorization", "").encode(), self._expected):
            raise AuthError("unauthorized", "A bearer token is required.")
        return Principal("dev")

    def describe(self) -> str:
        return "static bearer (dev)"


# --- JWTs -------------------------------------------------------------------------------


def _b64url(value: str) -> bytes:
    if not value or any(c in value for c in "=+/ \n"):
        raise AuthError("invalid_token", "The bearer token is malformed.")
    try:
        return base64.urlsafe_b64decode(value + "=" * (-len(value) % 4))
    except (binascii.Error, ValueError) as exc:
        raise AuthError("invalid_token", "The bearer token is malformed.") from exc


def _json_object(data: bytes) -> dict:
    try:
        doc = json.loads(data)
    except ValueError as exc:
        raise AuthError("invalid_token", "The bearer token is malformed.") from exc
    if not isinstance(doc, dict):
        raise AuthError("invalid_token", "The bearer token is malformed.")
    return doc


def _int_from_b64url(value: object) -> int:
    if not isinstance(value, str):
        raise ValueError("not a base64url string")
    return int.from_bytes(base64.urlsafe_b64decode(value + "=" * (-len(value) % 4)), "big")


_CURVES = {"P-256": (ec.SECP256R1, "ES256")}


def parse_jwks(data: bytes) -> dict[str, tuple[str, Any]]:
    """The signing keys of a JWKS document, by key id: ``{kid: (alg, key)}``.
    RSA keys (RS256) of at least 2048 bits and P-256 keys (ES256); others are
    skipped. Raises ``ValueError`` if none is usable."""
    if len(data) > MAX_JWKS_BYTES:
        raise ValueError("the JWKS document is too large")
    doc = json.loads(data)
    keys = doc.get("keys") if isinstance(doc, dict) else None
    if not isinstance(keys, list):
        raise ValueError("a JWKS document has a list of keys")
    found: dict[str, tuple[str, Any]] = {}
    for entry in keys:
        if not isinstance(entry, dict) or entry.get("use", "sig") != "sig":
            continue
        kid = entry.get("kid")
        if not isinstance(kid, str):
            continue
        try:
            if entry.get("kty") == "RSA" and entry.get("alg", "RS256") == "RS256":
                key = rsa.RSAPublicNumbers(_int_from_b64url(entry.get("e")), _int_from_b64url(entry.get("n"))).public_key()
                if key.key_size < MIN_RSA_BITS:
                    continue
                found[kid] = ("RS256", key)
            elif entry.get("kty") == "EC" and entry.get("crv") in _CURVES:
                curve, alg = _CURVES[entry["crv"]]
                if entry.get("alg", alg) != alg:
                    continue
                key = ec.EllipticCurvePublicNumbers(
                    _int_from_b64url(entry.get("x")), _int_from_b64url(entry.get("y")), curve()
                ).public_key()
                found[kid] = (alg, key)
        except (ValueError, binascii.Error):
            continue
    if not found:
        raise ValueError("the JWKS document holds no usable signing key")
    return found


def _verify_signature(alg: str, key: Any, signing_input: bytes, signature: bytes) -> bool:
    try:
        if alg == "RS256":
            key.verify(signature, signing_input, padding.PKCS1v15(), hashes.SHA256())
        elif alg == "ES256":
            if len(signature) != 64:
                return False
            r, s = int.from_bytes(signature[:32], "big"), int.from_bytes(signature[32:], "big")
            key.verify(encode_dss_signature(r, s), signing_input, ec.ECDSA(hashes.SHA256()))
        else:
            return False
    except InvalidSignature:
        return False
    return True


class JwksSource:
    """An issuer's published keys, fetched from its discovery document's
    ``jwks_uri`` and kept for ``ttl`` seconds; an unknown key id refetches,
    at most once every ``min_refetch`` seconds."""

    def __init__(self, issuer: str, *, transport: httpx.AsyncBaseTransport | None = None, ttl: float = 3600.0,
                 min_refetch: float = 60.0, clock: Callable[[], float] = time.monotonic) -> None:
        self.issuer = issuer.rstrip("/")
        self._client = httpx.AsyncClient(transport=transport, timeout=10.0)
        self._ttl = ttl
        self._min_refetch = min_refetch
        self._clock = clock
        self._keys: dict[str, tuple[str, Any]] = {}
        self._fetched_at: float | None = None
        self._jwks_uri: str | None = None
        self._lock = asyncio.Lock()

    async def aclose(self) -> None:
        await self._client.aclose()

    async def _fetch(self) -> None:
        if self._jwks_uri is None:
            resp = await self._client.get(f"{self.issuer}/.well-known/openid-configuration")
            resp.raise_for_status()
            disco = resp.json()
            if disco.get("issuer", "").rstrip("/") != self.issuer or not isinstance(disco.get("jwks_uri"), str):
                raise ValueError("the discovery document does not match the issuer")
            self._jwks_uri = disco["jwks_uri"]
        resp = await self._client.get(self._jwks_uri)
        resp.raise_for_status()
        self._keys = parse_jwks(resp.content)
        self._fetched_at = self._clock()

    async def key(self, kid: str | None) -> tuple[str, Any] | None:
        async with self._lock:
            now = self._clock()
            stale = self._fetched_at is None or now - self._fetched_at > self._ttl
            unknown = kid is not None and kid not in self._keys
            may_refetch = self._fetched_at is None or now - self._fetched_at > self._min_refetch
            if stale or (unknown and may_refetch):
                try:
                    await self._fetch()
                except (httpx.HTTPError, ValueError) as exc:
                    log.warning("the identity provider's keys could not be fetched: %s", type(exc).__name__)
                    if not self._keys:
                        raise AuthError("keys_unavailable", "The identity provider's keys are not available.",
                                        status=503) from exc
            if kid is None:
                return next(iter(self._keys.values())) if len(self._keys) == 1 else None
            return self._keys.get(kid)


class JwtVerifier:
    """Checks a bearer JWT against one issuer, its audiences and an allow-list
    of subjects."""

    def __init__(self, keys: JwksSource, *, issuer: str, audiences: Iterable[str], subjects: Iterable[str],
                 clock: Callable[[], float] = time.time, leeway: float = LEEWAY_SECONDS) -> None:
        self.keys = keys
        self.issuer = issuer.rstrip("/")
        self.audiences = frozenset(audiences)
        self.subjects = frozenset(subjects)
        self._clock = clock
        self._leeway = leeway
        if not self.audiences or not self.subjects:
            raise ValueError("a verifier needs an audience and an allowed subject")

    async def verify(self, token: str) -> Principal:
        if not token or len(token) > MAX_TOKEN_BYTES or not token.isascii():
            raise AuthError("invalid_token", "The bearer token is malformed.")
        parts = token.split(".")
        if len(parts) != 3:
            raise AuthError("invalid_token", "The bearer token is not a signed JWT.")
        header, claims, signature = _json_object(_b64url(parts[0])), _json_object(_b64url(parts[1])), _b64url(parts[2])
        alg = header.get("alg")
        if alg not in ("RS256", "ES256") or header.get("crit") is not None:
            raise AuthError("invalid_token", "The bearer token's algorithm is not accepted.")
        if str(claims.get("iss", "")).rstrip("/") != self.issuer:
            raise AuthError("invalid_token", "The bearer token's issuer is not trusted.")
        kid = header.get("kid") if isinstance(header.get("kid"), str) else None
        found = await self.keys.key(kid)
        if found is None or found[0] != alg:
            raise AuthError("invalid_token", "The bearer token's key is not known.")
        if not _verify_signature(alg, found[1], f"{parts[0]}.{parts[1]}".encode("ascii"), signature):
            raise AuthError("invalid_token", "The bearer token's signature does not verify.")
        self._check_claims(claims)
        return Principal(claims["sub"])

    def _check_claims(self, claims: Mapping[str, Any]) -> None:
        now, leeway = self._clock(), self._leeway
        aud = claims.get("aud")
        auds = {aud} if isinstance(aud, str) else {a for a in aud if isinstance(a, str)} if isinstance(aud, list) else set()
        if not auds & self.audiences:
            raise AuthError("invalid_token", "The bearer token is not for this relay.")
        exp = claims.get("exp")
        if not isinstance(exp, int | float) or isinstance(exp, bool):
            raise AuthError("invalid_token", "The bearer token has no expiry.")
        if exp + leeway < now:
            raise AuthError("token_expired", "The bearer token has expired.")
        nbf = claims.get("nbf")
        if isinstance(nbf, int | float) and nbf - leeway > now:
            raise AuthError("invalid_token", "The bearer token is not valid yet.")
        iat = claims.get("iat")
        if isinstance(iat, int | float) and iat - leeway > now:
            raise AuthError("invalid_token", "The bearer token was issued in the future.")
        sub = claims.get("sub")
        if not isinstance(sub, str) or sub not in self.subjects:
            raise AuthError("forbidden", "This account may not use the relay.", status=403)


class DoorAuth:
    """Real mode: a request forwarded by the Pocket ID door, for the owner, with
    a valid bearer from the app's sign-in (the module docstring)."""

    def __init__(self, verifier: JwtVerifier, *, owner_subject: str, trusted_proxies: Iterable[str] = ()) -> None:
        if not owner_subject:
            raise ValueError("the owner's subject is required")
        self.verifier = verifier
        self.owner_subject = owner_subject
        self.trusted_proxies = frozenset(p for p in trusted_proxies if p)

    async def authenticate(self, request: RequestLike) -> Principal:
        if self.trusted_proxies:
            peer = request.client.host if request.client else None
            if peer not in self.trusted_proxies:
                raise AuthError("not_through_door", "Requests reach the relay through its door only.", status=403)
        forwarded = request.headers.get("x-forwarded-user")
        if not forwarded:
            raise AuthError("unauthorized", "The door did not name a signed-in user.")
        header = request.headers.get("authorization", "")
        if not header.startswith("Bearer "):
            raise AuthError("unauthorized", "A bearer token is required.")
        principal = await self.verifier.verify(header[len("Bearer "):].strip())
        if principal.subject != self.owner_subject or not hmac.compare_digest(forwarded.encode(),
                                                                              self.owner_subject.encode()):
            raise AuthError("forbidden", "This account may not use the relay.", status=403)
        return principal

    def describe(self) -> str:
        door = "door peer checked" if self.trusted_proxies else "door peer not checked"
        return f"Pocket ID bearer ({self.verifier.issuer}, audience {', '.join(sorted(self.verifier.audiences))}; {door})"
