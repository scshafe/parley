"""A local APNs stand-in that speaks real HTTP/2 (h2c, prior knowledge) on
127.0.0.1, so the sender's HTTP/2 client, headers and answers are exercised
end to end. It verifies the provider token's ES256 signature with the test
key's public half. No Apple host is contacted."""

from __future__ import annotations

import asyncio
import base64
import json
from dataclasses import dataclass, field

import h2.config
import h2.connection
import h2.events
from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import encode_dss_signature


def _unb64(s: str) -> bytes:
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))


@dataclass
class FakeAPNs:
    public_key: ec.EllipticCurvePublicKey
    key_id: str
    team_id: str
    # device token -> (status, reason) to answer instead of 200
    answers: dict[str, tuple[int, str]] = field(default_factory=dict)
    # refuse the next N valid provider tokens as expired (each distinct token once)
    expire_next: int = 0
    requests: list[dict] = field(default_factory=list)
    server: asyncio.base_events.Server | None = None
    writers: set = field(default_factory=set)

    @property
    def url(self) -> str:
        host, port = self.server.sockets[0].getsockname()[:2]  # type: ignore[union-attr]
        return f"http://{host}:{port}"

    async def start(self) -> FakeAPNs:
        self.server = await asyncio.start_server(self._serve, "127.0.0.1", 0)
        return self

    async def stop(self) -> None:
        if self.server:
            self.server.close()
            for w in list(self.writers):  # a client the test left open must not hold the server
                w.close()
            await self.server.wait_closed()

    def _token_ok(self, jwt: str) -> bool:
        try:
            h, c, sig = jwt.split(".")
            header, claims = json.loads(_unb64(h)), json.loads(_unb64(c))
            raw = _unb64(sig)
            der = encode_dss_signature(int.from_bytes(raw[:32], "big"), int.from_bytes(raw[32:], "big"))
            self.public_key.verify(der, f"{h}.{c}".encode(), ec.ECDSA(hashes.SHA256()))
        except (ValueError, InvalidSignature):
            return False
        return header == {"alg": "ES256", "kid": self.key_id} and claims.get("iss") == self.team_id

    def _answer(self, headers: dict[str, str], body: bytes) -> tuple[int, dict]:
        path = headers.get(":path", "")
        device = path.removeprefix("/3/device/")
        auth = headers.get("authorization", "")
        jwt = auth.removeprefix("bearer ")
        self.requests.append({"path": path, "headers": headers, "body": json.loads(body or b"{}"), "device": device})
        if headers.get(":method") != "POST" or not path.startswith("/3/device/"):
            return 404, {"reason": "BadPath"}
        if not auth.startswith("bearer ") or not self._token_ok(jwt):
            return 403, {"reason": "InvalidProviderToken"}
        if self.expire_next > 0:
            self.expire_next -= 1
            return 403, {"reason": "ExpiredProviderToken"}
        if headers.get("apns-push-type") != "alert" or not headers.get("apns-topic"):
            return 400, {"reason": "MissingTopic"}
        if device in self.answers:
            status, reason = self.answers[device]
            return status, {"reason": reason}
        return 200, {}

    async def _serve(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        self.writers.add(writer)
        conn = h2.connection.H2Connection(config=h2.config.H2Configuration(client_side=False))
        conn.initiate_connection()
        writer.write(conn.data_to_send())
        streams: dict[int, tuple[dict[str, str], bytearray]] = {}
        try:
            while True:
                data = await reader.read(65535)
                if not data:
                    break
                for event in conn.receive_data(data):
                    if isinstance(event, h2.events.RequestReceived):
                        hdrs = {(k.decode() if isinstance(k, bytes) else k): (v.decode() if isinstance(v, bytes) else v)
                                for k, v in event.headers}
                        streams[event.stream_id] = (hdrs, bytearray())
                    elif isinstance(event, h2.events.DataReceived):
                        streams[event.stream_id][1].extend(event.data)
                        conn.acknowledge_received_data(event.flow_controlled_length, event.stream_id)
                    elif isinstance(event, h2.events.StreamEnded):
                        hdrs, body = streams.pop(event.stream_id)
                        status, payload = self._answer(hdrs, bytes(body))
                        out = json.dumps(payload).encode() if payload else b""
                        conn.send_headers(event.stream_id, [(":status", str(status)), ("apns-id", f"id-{event.stream_id}"),
                                                            ("content-length", str(len(out)))],
                                          end_stream=not out)
                        if out:
                            conn.send_data(event.stream_id, out, end_stream=True)
                    elif isinstance(event, h2.events.ConnectionTerminated):
                        return
                writer.write(conn.data_to_send())
                await writer.drain()
        except ConnectionError:
            pass
        finally:
            self.writers.discard(writer)
            writer.close()
