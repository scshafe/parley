"""The relay's HTTP API, for the app, and the voice-lab webhook.

App routes (``Authorization: Bearer``; who may use them is the
:mod:`parley_relay.auth` authenticator's choice):

- ``POST /api/v1/conversations`` ``{title?}`` → 201 conversation
- ``GET  /api/v1/conversations`` → ``{conversations: [...]}``, newest first
- ``GET  /api/v1/conversations/{id}`` → the conversation with its turns
- ``POST /api/v1/conversations/{id}/turns`` ``{text, client_turn_id}`` → 202 turn
  (200 for a retry of the same ``client_turn_id`` and text, 409 for another text)
- ``GET  /api/v1/conversations/{id}/turns/{turn}`` → turn
- ``GET  /api/v1/conversations/{id}/events`` → SSE of ``turn.updated`` events,
  resumable with ``Last-Event-ID`` or ``?after=``
- ``GET  /api/v1/conversations/{id}/turns/{turn}/audio`` → WAV, single ``Range``
- ``GET  /api/v1/conversations/{id}/turns/{turn}/timings.json``

Webhook (Standard Webhooks signature, no bearer): ``POST /hooks/voice-lab``.
Unauthenticated: ``GET /healthz``.
"""

from __future__ import annotations

import asyncio
import json
import logging
import re
from collections.abc import AsyncIterator, Callable
from contextlib import asynccontextmanager

from starlette.applications import Starlette
from starlette.requests import Request
from starlette.responses import JSONResponse, Response, StreamingResponse
from starlette.routing import Route

from .auth import AuthError, Authenticator, StaticTokenAuth
from .http_range import ranged
from .pipeline import Pipeline
from .store import ConflictError, Store
from .views import conversation_json, turn_json
from .secretfiles import SecretFileError
from .voicelab import WebhookError, WebhookSecret, verify_webhook

WebhookSecretSource = Callable[[], "WebhookSecret | None"]

log = logging.getLogger("parley.api")

_CLIENT_TURN_ID = re.compile(r"^[A-Za-z0-9._:-]{1,100}$")
MAX_TURN_CHARACTERS = 4000


def error(status: int, code: str, detail: str = "") -> JSONResponse:
    return JSONResponse({"error": {"code": code, "detail": detail or code.replace("_", " ")}}, status_code=status,
                        headers={"cache-control": "no-store"})


def ok(body: object, status: int = 200) -> JSONResponse:
    return JSONResponse(body, status_code=status, headers={"cache-control": "no-store"})


def build_app(
    *,
    store: Store,
    pipeline: Pipeline,
    token: str | None = None,
    auth: Authenticator | None = None,
    webhook_secret: WebhookSecret | WebhookSecretSource | None = None,
    stream_heartbeat: float = 15.0,
    stream_max_seconds: float = 600.0,
    on_startup: Callable[[], object] | None = None,
    on_shutdown: Callable[[], object] | None = None,
) -> Starlette:
    if auth is None:
        if not token:
            raise ValueError("the relay needs an authenticator or a bearer token")
        auth = StaticTokenAuth(token)
    authenticator = auth
    if isinstance(webhook_secret, WebhookSecret):
        fixed = webhook_secret

        def secret_source() -> WebhookSecret | None:
            return fixed
    else:
        secret_source = webhook_secret  # type: ignore[assignment]

    def guard(handler):  # type: ignore[no-untyped-def]
        async def wrapped(request: Request) -> Response:
            try:
                request.state.principal = await authenticator.authenticate(request)
            except AuthError as exc:
                resp = error(exc.status, exc.code, exc.detail)
                if exc.status == 401:
                    resp.headers["www-authenticate"] = 'Bearer realm="parley"'
                return resp
            return await handler(request)

        return wrapped

    def conversation_or_404(request: Request) -> dict | None:
        return store.get_conversation(request.path_params["cid"])

    def turn_or_404(request: Request) -> dict | None:
        t = store.get_turn(request.path_params["tid"])
        if t is None or t["conversation_id"] != request.path_params["cid"]:
            return None
        return t

    async def json_body(request: Request) -> dict | None:
        try:
            body = await request.json()
        except (ValueError, UnicodeDecodeError):
            return None
        return body if isinstance(body, dict) else None

    async def healthz(request: Request) -> Response:
        return ok({"ok": True})

    async def create_conversation(request: Request) -> Response:
        body = await json_body(request) if await request.body() else {}
        if body is None:
            return error(422, "invalid_request", "The body is not a JSON object.")
        title = body.get("title")
        if title is not None and (not isinstance(title, str) or len(title) > 200):
            return error(422, "invalid_request", "A title is a string of at most 200 characters.")
        conv = store.create_conversation(title.strip() if isinstance(title, str) and title.strip() else None)
        return ok(conversation_json(conv), 201)

    async def list_conversations(request: Request) -> Response:
        return ok({"conversations": [conversation_json(c) for c in store.list_conversations()]})

    async def get_conversation(request: Request) -> Response:
        conv = conversation_or_404(request)
        if conv is None:
            return error(404, "conversation_not_found")
        return ok(conversation_json(conv, store.turns_of(conv["id"])))

    async def create_turn(request: Request) -> Response:
        conv = conversation_or_404(request)
        if conv is None:
            return error(404, "conversation_not_found")
        body = await json_body(request)
        if body is None:
            return error(422, "invalid_request", "The body is not a JSON object.")
        text, ctid = body.get("text"), body.get("client_turn_id")
        if not isinstance(text, str) or not text.strip() or len(text) > MAX_TURN_CHARACTERS:
            return error(422, "invalid_request", f"The text is 1 to {MAX_TURN_CHARACTERS} characters.")
        if not isinstance(ctid, str) or not _CLIENT_TURN_ID.match(ctid):
            return error(422, "invalid_request", "client_turn_id is 1 to 100 of [A-Za-z0-9._:-].")
        try:
            turn, created = store.add_turn(conv["id"], ctid, text.strip())
        except ConflictError:
            return error(409, "client_turn_conflict", "That client_turn_id was used with another text.")
        if created:
            store.add_event(conv["id"], "turn.updated", turn_json(turn))
            pipeline.bus.notify(conv["id"])
            pipeline.submit(turn["id"])
        return ok(turn_json(turn), 202 if created else 200)

    async def get_turn(request: Request) -> Response:
        t = turn_or_404(request)
        if t is None:
            return error(404, "turn_not_found")
        return ok(turn_json(t))

    async def turn_audio(request: Request) -> Response:
        t = turn_or_404(request)
        if t is None:
            return error(404, "turn_not_found")
        if t["state"] != "ready":
            return error(409, "audio_not_ready")
        path = store.turn_dir(t["id"]) / "reply.wav"
        if t["audio_deleted"] or not path.exists():
            return error(410, "audio_expired")
        data = await asyncio.to_thread(path.read_bytes)
        return ranged(request, data, "audio/wav", extra_headers={"cache-control": "private, max-age=86400"})

    async def turn_timings(request: Request) -> Response:
        t = turn_or_404(request)
        if t is None:
            return error(404, "turn_not_found")
        if t["state"] != "ready":
            return error(409, "timings_not_ready")
        path = store.turn_dir(t["id"]) / "timings.json"
        if not path.exists():
            return error(410, "timings_missing")
        return Response(path.read_bytes(), media_type="application/json",
                        headers={"cache-control": "private, max-age=86400"})

    async def events(request: Request) -> Response:
        conv = conversation_or_404(request)
        if conv is None:
            return error(404, "conversation_not_found")
        raw = request.headers.get("last-event-id") or request.query_params.get("after") or "0"
        after = int(raw) if raw.isdigit() else 0
        return StreamingResponse(
            event_stream(store, pipeline, conv["id"], after, heartbeat=stream_heartbeat, max_seconds=stream_max_seconds),
            media_type="text/event-stream",
            headers={"cache-control": "no-store", "x-accel-buffering": "no"},
        )

    async def voice_lab_webhook(request: Request) -> Response:
        if secret_source is None:
            return error(404, "not_found")
        try:
            secret = secret_source()
        except SecretFileError as exc:
            log.warning("webhook refused: %s", exc)
            secret = None
        if secret is None:
            # Not configured yet (no secret file): voice-lab retries, and the
            # relay's own polling is the backstop.
            return error(503, "webhook_not_configured")
        body = await request.body()
        try:
            verify_webhook(secret, request.headers, body)
        except WebhookError:
            return error(401, "bad_signature")
        try:
            event = json.loads(body)
            data = event["data"]
            job_id = str(data["id"])
        except (ValueError, KeyError, TypeError):
            return error(400, "bad_event")
        turn_id = store.turn_for_job(job_id)
        if turn_id is None:
            # The webhook can beat the relay's own record of the job; the
            # client_ref names the turn.
            parts = str(data.get("client_ref") or "").split("/")
            turn_id = parts[1] if len(parts) >= 2 else None
            if turn_id is None or store.get_turn(turn_id) is None:
                return error(410, "unknown_job")
        pipeline.wake(turn_id)
        return Response(status_code=204)

    @asynccontextmanager
    async def lifespan(app: Starlette) -> AsyncIterator[None]:
        if on_startup:
            res = on_startup()
            if asyncio.iscoroutine(res):
                await res
        await pipeline.start()
        try:
            yield
        finally:
            await pipeline.stop()
            if on_shutdown:
                res = on_shutdown()
                if asyncio.iscoroutine(res):
                    await res

    routes = [
        Route("/healthz", healthz, methods=["GET"]),
        Route("/api/v1/conversations", guard(create_conversation), methods=["POST"]),
        Route("/api/v1/conversations", guard(list_conversations), methods=["GET"]),
        Route("/api/v1/conversations/{cid}", guard(get_conversation), methods=["GET"]),
        Route("/api/v1/conversations/{cid}/turns", guard(create_turn), methods=["POST"]),
        Route("/api/v1/conversations/{cid}/events", guard(events), methods=["GET"]),
        Route("/api/v1/conversations/{cid}/turns/{tid}", guard(get_turn), methods=["GET"]),
        Route("/api/v1/conversations/{cid}/turns/{tid}/audio", guard(turn_audio), methods=["GET", "HEAD"]),
        Route("/api/v1/conversations/{cid}/turns/{tid}/timings.json", guard(turn_timings), methods=["GET"]),
        Route("/hooks/voice-lab", voice_lab_webhook, methods=["POST"]),
    ]
    return Starlette(routes=routes, lifespan=lifespan)


async def event_stream(store: Store, pipeline: Pipeline, cid: str, after: int, *, heartbeat: float = 15.0,
                       max_seconds: float = 600.0) -> AsyncIterator[str]:
    """A conversation's events after ``after``, then each new one as it comes,
    with a comment every ``heartbeat`` seconds; closed after ``max_seconds``
    (the app reconnects with ``Last-Event-ID``)."""
    loop = asyncio.get_running_loop()
    end = loop.time() + max_seconds
    cursor = after
    yield "retry: 2000\n\n"
    while True:
        waiter = pipeline.bus.waiter(cid)
        for ev in store.events_after(cid, cursor):
            cursor = ev["id"]
            yield f"id: {ev['id']}\nevent: {ev['type']}\ndata: {ev['data_json']}\n\n"
        remaining = end - loop.time()
        if remaining <= 0:
            return
        try:
            await asyncio.wait_for(waiter.wait(), min(heartbeat, remaining))
        except TimeoutError:
            yield ": keep-alive\n\n"
