"""A fake of voice-lab's speech API, for tests and for ``parley-relay --dev``.

It follows voice-lab ``docs/SPEECH_API.md`` (§6 endpoints, §7 sentences, §8
webhooks) closely enough that the relay's client cannot tell the difference,
but it renders SYNTHETIC audio only: soft tone bursts and silence with plausible
durations. It has no voice, no model and no voice-lab asset, and it never
touches the network: webhooks go through the ``deliver`` callable it is given.
"""

from __future__ import annotations

import asyncio
import hashlib
import json
import re
import time
import unicodedata
from collections.abc import Awaitable, Callable
from dataclasses import dataclass, field
from datetime import UTC, datetime
from typing import Any
from urllib.parse import urlsplit

from starlette.applications import Starlette
from starlette.requests import Request
from starlette.responses import JSONResponse, Response, StreamingResponse
from starlette.routing import Route

from . import audio
from .http_range import etag_for, ranged
from .sentences import voice_lab_sentences
from .voicelab import WebhookSecret

Deliver = Callable[[str, dict[str, str], bytes], Awaitable[int]]

_KEY = re.compile(r"^[A-Za-z0-9._:-]{1,128}$")
_FIELDS = {"text", "format", "callback_url", "idempotency_key", "client_ref"}
MAX_BODY_BYTES = 64 * 1024


def _now() -> str:
    return datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def refusal(status: int, code: str, detail: str = "", headers: dict[str, str] | None = None) -> JSONResponse:
    h = {"cache-control": "no-store"}
    if headers:
        h.update(headers)
    return JSONResponse({"error": code, "detail": detail or code.replace("_", " ")}, status_code=status, headers=h)


def _ok(body: Any, status: int = 200) -> JSONResponse:
    return JSONResponse(body, status_code=status, headers={"cache-control": "no-store"})


@dataclass
class _Segment:
    index: int
    wav: bytes
    duration_ms: int
    text_start: int
    text_end: int

    @property
    def sha256(self) -> str:
        return hashlib.sha256(self.wav).hexdigest()


@dataclass
class _Job:
    id: str
    text: str | None
    text_characters: int
    client_ref: str | None
    callback_url: str | None
    created: float
    created_at: str
    state: str = "queued"
    started_at: str | None = None
    finished_at: str | None = None
    started: float | None = None
    finished: float | None = None
    segment_count: int | None = None
    segments: list[_Segment] = field(default_factory=list)
    joined: bytes | None = None
    error: dict | None = None
    cancel_requested: bool = False
    changed: asyncio.Event = field(default_factory=asyncio.Event)
    deliveries: list[int] = field(default_factory=list)

    def links(self) -> dict[str, str]:
        base = f"/api/v1/speech/{self.id}"
        return {"self": base, "audio": f"{base}/audio", "events": f"{base}/events", "cancel": f"{base}/cancel"}


class FakeVoiceLab:
    """The fake service. ``speed`` scales render time to the audio's duration
    (voice-lab renders at about 0.7x real time on the PC; ``0`` renders at
    once). ``autorun`` starts rendering when a job is accepted; tests may turn it
    off and call :meth:`render` themselves."""

    def __init__(
        self,
        *,
        token: str | None = "fake-voice-lab-token",
        secret: WebhookSecret | None = None,
        webhook_urls: tuple[str, ...] = ("https://parley.example.ts.net/hooks/voice-lab",),
        tailnet_suffix: str = "example.ts.net",
        deliver: Deliver | None = None,
        speed: float = 0.0,
        autorun: bool = True,
        max_text_characters: int = 2000,
        max_queued_jobs: int = 4,
        report_ranges: bool = False,
        max_sentence_chars: int | None = None,
    ) -> None:
        self.token = token
        self.secret = secret
        self.webhook_urls = webhook_urls
        self.tailnet_suffix = tailnet_suffix
        self.deliver = deliver
        self.speed = speed
        self.autorun = autorun
        self.max_text_characters = max_text_characters
        self.max_queued_jobs = max_queued_jobs
        self.report_ranges = report_ranges
        self.max_sentence_chars = max_sentence_chars
        self.jobs: dict[str, _Job] = {}
        self.idempotency: dict[str, tuple[str, str]] = {}
        self.fail_next: str | None = None  # an error code the next render ends with
        self.gpu_busy_seconds: int | None = None  # answer 503 gpu_busy while set
        self.requests: list[dict] = []  # accepted request bodies, for tests
        self._seq = 0
        self._tasks: set[asyncio.Task] = set()
        self.app = Starlette(
            routes=[
                Route("/api/v1/speech", self._create, methods=["POST"]),
                Route("/api/v1/speech/{id}", self._status, methods=["GET"]),
                Route("/api/v1/speech/{id}/audio", self._audio, methods=["GET", "HEAD"]),
                Route("/api/v1/speech/{id}/segments/{n}/audio", self._segment_audio, methods=["GET", "HEAD"]),
                Route("/api/v1/speech/{id}/events", self._events, methods=["GET"]),
                Route("/api/v1/speech/{id}/cancel", self._cancel, methods=["POST"]),
                Route("/api/v1/speech/{rest:path}", self._not_found,
                      methods=["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE"]),
            ],
        )
        self.app.add_exception_handler(405, self._method_not_allowed)  # type: ignore[arg-type]

    # --- helpers -----------------------------------------------------------------------

    async def _method_not_allowed(self, request: Request, exc: Exception) -> Response:
        return refusal(405, "method_not_allowed")

    async def _not_found(self, request: Request) -> Response:
        return refusal(404, "not_found")

    def _authorized(self, request: Request) -> bool:
        if self.token is None:
            return True
        return request.headers.get("authorization", "") == f"Bearer {self.token}"

    def _job(self, request: Request) -> _Job | None:
        return self.jobs.get(request.path_params["id"])

    def status_body(self, job: _Job) -> dict:
        segs = [
            {
                "index": s.index,
                "sha256": s.sha256,
                "bytes": len(s.wav),
                "duration_ms": s.duration_ms,
                "audio": f"/api/v1/speech/{job.id}/segments/{s.index}/audio",
                **({"text_start": s.text_start, "text_end": s.text_end} if self.report_ranges else {}),
            }
            for s in job.segments
        ]
        return {
            "id": job.id,
            "state": job.state,
            "client_ref": job.client_ref,
            "format": "wav",
            "text_characters": job.text_characters,
            "created_at": job.created_at,
            "started_at": job.started_at,
            "finished_at": job.finished_at,
            "queue_ms": round((job.started - job.created) * 1000) if job.started else None,
            "render_ms": round((job.finished - job.started) * 1000) if job.finished and job.started else None,
            "segment_count": job.segment_count,
            "segments": segs,
            "audio": self._audio_summary(job),
            "error": job.error,
            "links": job.links(),
        }

    def _audio_summary(self, job: _Job) -> dict | None:
        if job.state != "succeeded" or job.joined is None:
            return None
        return {
            "sha256": hashlib.sha256(job.joined).hexdigest(),
            "bytes": len(job.joined),
            "duration_ms": audio.info(job.joined).duration_ms,
            "format": "wav",
        }

    def _callback_allowed(self, url: str) -> bool:
        try:
            u = urlsplit(url)
            port = u.port or 443
        except ValueError:
            return False
        if u.scheme != "https" or u.username or u.password or u.query or u.fragment or not u.hostname:
            return False
        host = u.hostname.lower()
        suffix = "." + self.tailnet_suffix.lower()
        if not host.endswith(suffix) or "." in host[: -len(suffix)] or not host[: -len(suffix)]:
            return False
        segs = u.path.split("/")[1:]
        if any(s in ("", ".", "..") or ";" in s or re.search(r"%(2e|2f|3b|5c)", s, re.I) for s in segs):
            return False
        for allowed in self.webhook_urls:
            a = urlsplit(allowed)
            if (a.hostname or "").lower() != host or (a.port or 443) != port:
                continue
            asegs = a.path.split("/")[1:]
            if segs[: len(asegs)] == asegs:
                return True
        return False

    # --- POST /api/v1/speech -----------------------------------------------------------

    async def _create(self, request: Request) -> Response:
        if not self._authorized(request):
            return refusal(401, "unauthorized")
        raw = await request.body()
        if len(raw) > MAX_BODY_BYTES:
            return refusal(413, "request_too_large")
        try:
            body = json.loads(raw)
        except ValueError:
            return refusal(422, "invalid_request", "The body is not JSON.")
        if not isinstance(body, dict) or set(body) - _FIELDS:
            return refusal(422, "invalid_request", "Unknown or missing fields.")
        text = body.get("text")
        fmt = body.get("format", "wav")
        cb = body.get("callback_url")
        key = body.get("idempotency_key")
        ref = body.get("client_ref")
        if not isinstance(text, str) or not 1 <= len(text) <= self.max_text_characters or not text.strip():
            return refusal(422, "invalid_request", "The text is empty or too long.")
        if any(ch != "\n" and unicodedata.category(ch) in ("Cc", "Cf") for ch in text):
            return refusal(422, "invalid_request", "The text has a control or format character.")
        if fmt == "ogg-opus":
            return refusal(422, "unsupported_format")
        if fmt != "wav":
            return refusal(422, "invalid_request", "Unknown format.")
        if cb is not None and (not isinstance(cb, str) or not self._callback_allowed(cb)):
            return refusal(422, "callback_not_allowed")
        if key is not None and (not isinstance(key, str) or not _KEY.match(key)):
            return refusal(422, "invalid_request", "Bad idempotency key.")
        if ref is not None and (not isinstance(ref, str) or len(ref) > 200):
            return refusal(422, "invalid_request", "Bad client_ref.")
        digest = hashlib.sha256(json.dumps([text, fmt, cb, ref]).encode()).hexdigest()
        if key is not None and key in self.idempotency:
            seen_digest, job_id = self.idempotency[key]
            if seen_digest != digest:
                return refusal(409, "idempotency_conflict")
            return _ok(self.status_body(self.jobs[job_id]), 200)
        if self.gpu_busy_seconds is not None:
            return refusal(503, "gpu_busy", headers={"retry-after": str(self.gpu_busy_seconds)})
        active = sum(1 for j in self.jobs.values() if j.state in ("queued", "running"))
        if active >= self.max_queued_jobs:
            return refusal(429, "too_many_jobs")
        self._seq += 1
        job_id = "sp-" + hashlib.sha256(f"{self._seq}-{time.time_ns()}".encode()).hexdigest()[:24]
        job = _Job(job_id, text, len(text), ref, cb, time.monotonic(), _now())
        self.jobs[job_id] = job
        if key is not None:
            self.idempotency[key] = (digest, job_id)
        self.requests.append(dict(body))
        if self.autorun:
            task = asyncio.get_running_loop().create_task(self.render(job_id))
            self._tasks.add(task)
            task.add_done_callback(self._tasks.discard)
        return _ok(self.status_body(job), 202)

    # --- rendering ------------------------------------------------------------------------

    async def render(self, job_id: str) -> None:
        """Run a queued job to its end: one synthetic segment per sentence, then
        the joined audio and the webhook."""
        job = self.jobs[job_id]
        if job.state != "queued":
            return
        job.state, job.started, job.started_at = "running", time.monotonic(), _now()
        text = job.text or ""
        spans = voice_lab_sentences(text, max_sentence_chars=self.max_sentence_chars)
        job.segment_count = len(spans)
        self._pulse(job)
        failure, self.fail_next = self.fail_next, None
        for i, span in enumerate(spans, start=1):
            if job.cancel_requested:
                break
            if failure and i == max(1, len(spans) // 2 + 1):
                break
            wav = audio.synthetic_sentence(span.of(text), seed=i)
            dur = audio.info(wav).duration_ms
            if self.speed:
                await asyncio.sleep(dur / 1000 * self.speed)
            job.segments.append(_Segment(i, wav, dur, span.start, span.end))
            self._pulse(job)
        job.text = None  # "the job's input is deleted when the job ends"
        job.finished, job.finished_at = time.monotonic(), _now()
        if job.cancel_requested:
            job.state = "cancelled"
        elif failure:
            job.state = "failed"
            job.error = {"code": failure, "detail": "The render failed."}
        else:
            job.joined = audio.join([s.wav for s in job.segments])
            job.state = "succeeded"
        self._pulse(job)
        await self._send_webhook(job)

    def _pulse(self, job: _Job) -> None:
        job.changed.set()
        job.changed = asyncio.Event()

    def webhook_event(self, job: _Job) -> dict:
        return {
            "type": f"speech.{job.state}",
            "timestamp": _now(),
            "data": {
                "id": job.id,
                "state": job.state,
                "client_ref": job.client_ref,
                "segment_count": job.segment_count,
                "audio": self._audio_summary(job),
                "error": job.error,
                "links": job.links(),
            },
        }

    async def _send_webhook(self, job: _Job) -> None:
        if not job.callback_url or self.deliver is None or self.secret is None:
            return
        body = json.dumps(self.webhook_event(job), separators=(",", ":")).encode()
        msg_id = f"msg_{job.id}"
        for attempt in range(3):
            ts = int(time.time())
            headers = {
                "content-type": "application/json",
                "webhook-id": msg_id,
                "webhook-timestamp": str(ts),
                "webhook-signature": self.secret.sign(msg_id, ts, body),
            }
            try:
                status = await self.deliver(job.callback_url, headers, body)
            except Exception:  # noqa: BLE001 - a failed attempt is retried
                status = 0
            job.deliveries.append(status)
            if 200 <= status < 300 or status == 410:
                return
            await asyncio.sleep(0.05 * (attempt + 1))

    def expire(self, job_id: str) -> None:
        job = self.jobs[job_id]
        job.joined = None
        for s in job.segments:
            s.wav = b""
        job.state = "expired"
        self._pulse(job)

    async def drain(self) -> None:
        while self._tasks:
            await asyncio.gather(*list(self._tasks), return_exceptions=True)

    # --- reads ----------------------------------------------------------------------------

    async def _status(self, request: Request) -> Response:
        if not self._authorized(request):
            return refusal(401, "unauthorized")
        job = self._job(request)
        if job is None:
            return refusal(404, "speech_not_found")
        return _ok(self.status_body(job))

    async def _audio(self, request: Request) -> Response:
        if not self._authorized(request):
            return refusal(401, "unauthorized")
        job = self._job(request)
        if job is None:
            return refusal(404, "speech_not_found")
        if job.state == "expired":
            return refusal(410, "audio_expired")
        if job.state != "succeeded" or job.joined is None:
            return refusal(409, "audio_not_ready")
        return ranged(request, job.joined, "audio/wav", etag=etag_for(job.joined),
                      extra_headers={"cache-control": "no-store"})

    async def _segment_audio(self, request: Request) -> Response:
        if not self._authorized(request):
            return refusal(401, "unauthorized")
        job = self._job(request)
        if job is None:
            return refusal(404, "speech_not_found")
        try:
            n = int(request.path_params["n"])
        except ValueError:
            return refusal(404, "not_found")
        if n < 1 or (job.segment_count is not None and n > job.segment_count):
            return refusal(404, "not_found")
        if job.state == "expired":
            return refusal(410, "audio_expired")
        if n > len(job.segments):
            return refusal(409, "audio_not_ready")
        wav = job.segments[n - 1].wav
        return ranged(request, wav, "audio/wav", extra_headers={"cache-control": "no-store"})

    async def _events(self, request: Request) -> Response:
        if not self._authorized(request):
            return refusal(401, "unauthorized")
        job = self._job(request)
        if job is None:
            return refusal(404, "speech_not_found")
        last = request.headers.get("last-event-id", "")
        after = int(last) if re.fullmatch(r"\d{1,4}", last) else 0
        return StreamingResponse(self.event_stream(job, after), media_type="text/event-stream",
                                 headers={"cache-control": "no-store"})

    async def event_stream(self, job: _Job, after: int = 0, heartbeat: float = 15.0):
        sent = after
        while True:
            while sent < len(job.segments):
                seg = job.segments[sent]
                data = {"index": seg.index, "sha256": seg.sha256, "bytes": len(seg.wav),
                        "duration_ms": seg.duration_ms,
                        "audio": f"/api/v1/speech/{job.id}/segments/{seg.index}/audio"}
                yield f"id: {seg.index}\nevent: segment.ready\ndata: {json.dumps(data)}\n\n"
                sent += 1
            if job.state in ("succeeded", "failed", "cancelled", "expired"):
                yield f"id: end\nevent: speech.{job.state}\ndata: {json.dumps(self.status_body(job))}\n\n"
                return
            try:
                await asyncio.wait_for(job.changed.wait(), heartbeat)
            except TimeoutError:
                yield ": keep-alive\n\n"

    async def _cancel(self, request: Request) -> Response:
        if not self._authorized(request):
            return refusal(401, "unauthorized")
        job = self._job(request)
        if job is None:
            return refusal(404, "speech_not_found")
        if job.state in ("succeeded", "failed", "cancelled", "expired"):
            return JSONResponse({"error": "already_finished", "detail": "The job has ended.", "state": job.state},
                                status_code=409, headers={"cache-control": "no-store"})
        if job.state == "queued":
            job.state, job.finished_at, job.text = "cancelled", _now(), None
            self._pulse(job)
            await self._send_webhook(job)
        else:
            job.cancel_requested = True
        return _ok(self.status_body(job), 202)
