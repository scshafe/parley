"""A local stand-in for Pocket ID (discovery, JWKS, the token endpoint) and
test-only signing keys, made fresh for each run. No real key or token."""

from __future__ import annotations

import base64
import json
import time
from dataclasses import dataclass, field
from urllib.parse import parse_qs

import httpx
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import ec, padding, rsa
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature

ISSUER = "https://id.example.ts.net"
OWNER = "00000000-test-owner-0000-000000000001"


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def _int(n: int) -> str:
    return b64url(n.to_bytes((n.bit_length() + 7) // 8, "big"))


@dataclass
class SigningKey:
    kid: str
    alg: str = "RS256"
    key: object = None

    def __post_init__(self) -> None:
        if self.key is None:
            self.key = (rsa.generate_private_key(public_exponent=65537, key_size=2048) if self.alg == "RS256"
                        else ec.generate_private_key(ec.SECP256R1()))

    def jwk(self) -> dict:
        pub = self.key.public_key().public_numbers()  # type: ignore[attr-defined]
        if self.alg == "RS256":
            return {"kty": "RSA", "use": "sig", "alg": "RS256", "kid": self.kid, "n": _int(pub.n), "e": _int(pub.e)}
        return {"kty": "EC", "use": "sig", "alg": "ES256", "crv": "P-256", "kid": self.kid,
                "x": b64url(pub.x.to_bytes(32, "big")), "y": b64url(pub.y.to_bytes(32, "big"))}

    def sign(self, claims: dict, header: dict | None = None) -> str:
        h = {"alg": self.alg, "typ": "JWT", "kid": self.kid, **(header or {})}
        signing_input = f"{b64url(json.dumps(h).encode())}.{b64url(json.dumps(claims).encode())}".encode()
        if self.alg == "RS256":
            sig = self.key.sign(signing_input, padding.PKCS1v15(), hashes.SHA256())  # type: ignore[attr-defined]
        else:
            r, s = decode_dss_signature(self.key.sign(signing_input, ec.ECDSA(hashes.SHA256())))  # type: ignore[attr-defined]
            sig = r.to_bytes(32, "big") + s.to_bytes(32, "big")
        return f"{signing_input.decode()}.{b64url(sig)}"


def claims(**over) -> dict:
    now = int(time.time())
    c = {"iss": ISSUER, "sub": OWNER, "aud": "parley-ios", "iat": now, "exp": now + 3600, "email": "owner@example.com"}
    c.update(over)
    return {k: v for k, v in c.items() if v is not None}


@dataclass
class FakeProvider:
    """Discovery, JWKS and a client-credentials token endpoint."""

    keys: list[SigningKey] = field(default_factory=lambda: [SigningKey("k1")])
    client_id: str = "parley-relay"
    client_secret: str = "test-client-secret"
    expires_in: int | None = 3600
    token_status: int = 200
    jwks_hits: int = 0
    token_requests: list[dict] = field(default_factory=list)
    issued: list[str] = field(default_factory=list)

    def handler(self, request: httpx.Request) -> httpx.Response:
        path = request.url.path
        if path == "/.well-known/openid-configuration":
            return httpx.Response(200, json={"issuer": ISSUER, "jwks_uri": f"{ISSUER}/.well-known/jwks.json",
                                             "token_endpoint": f"{ISSUER}/api/oidc/token"})
        if path == "/.well-known/jwks.json":
            self.jwks_hits += 1
            return httpx.Response(200, json={"keys": [k.jwk() for k in self.keys]})
        if path == "/api/oidc/token" and request.method == "POST":
            form = {k: v[0] for k, v in parse_qs(request.content.decode()).items()}
            self.token_requests.append({"authorization": request.headers.get("authorization"), "form": form})
            expected = "Basic " + base64.b64encode(f"{self.client_id}:{self.client_secret}".encode()).decode()
            if request.headers.get("authorization") != expected or form.get("grant_type") != "client_credentials":
                return httpx.Response(401, json={"error": "invalid_client"})
            if self.token_status != 200:
                return httpx.Response(self.token_status, json={"error": "server_error"})
            token = self.keys[0].sign(claims(sub=f"client-{self.client_id}", aud=self.client_id, email=None,
                                             n=len(self.issued)))
            self.issued.append(token)
            body = {"access_token": token, "token_type": "Bearer"}
            if self.expires_in is not None:
                body["expires_in"] = self.expires_in
            return httpx.Response(200, json=body)
        return httpx.Response(404)

    def transport(self) -> httpx.MockTransport:
        # Late-bound, so a test can swap `handler` (an outage, another discovery).
        return httpx.MockTransport(lambda request: self.handler(request))
