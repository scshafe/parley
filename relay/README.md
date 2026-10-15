# parley-relay

The relay between the Parley app and the agent and voice-lab. Design:
[docs/DESIGN.md](../docs/DESIGN.md).

## Run it locally (dev mode)

```sh
cd relay
uv run parley-relay --dev            # http://127.0.0.1:8765, bearer token: parley-dev
```

`--dev` runs the fake agent (canned, speech-style replies) and the fake
voice-lab (SYNTHETIC tones, never speech) in-process; webhooks go from the fake
straight into the relay app. Nothing leaves the machine. Data goes to
`relay/.parley-dev/` (or `--data-dir`). Options: `--port`, `--host`,
`--fake-agent-delay` (seconds, default 1), `--fake-speech-speed` (render time as
a fraction of audio length, default 0.3).

A turn by hand:

```sh
H='authorization: Bearer parley-dev'
C=$(curl -s -XPOST -H "$H" localhost:8765/api/v1/conversations -d '{}' | jq -r .id)
curl -s -XPOST -H "$H" localhost:8765/api/v1/conversations/$C/turns \
  -d '{"text": "What should I cook tonight?", "client_turn_id": "t1"}'
curl -sN -H "$H" localhost:8765/api/v1/conversations/$C/events   # thinking, speaking, ready
```

The fake agent takes a hint from a few words: `long` (a reply over 2,000
characters, so several speech jobs), `link` (an attachment), `markdown` (text
the relay must clean up), `fail` (the agent fails).

## API

All `/api/v1` routes take `Authorization: Bearer <token>`; errors are
`{"error": {"code", "detail"}}`.

| Route | |
| --- | --- |
| `POST /api/v1/conversations` `{title?}` | 201, the conversation |
| `GET /api/v1/conversations` | `{conversations}`, newest first |
| `GET /api/v1/conversations/{id}` | the conversation with `turns` and `last_event_id` |
| `POST /api/v1/conversations/{id}/turns` `{text, client_turn_id}` | 202, the turn in `thinking`; a retry with the same `client_turn_id` answers 200 with the same turn, another text 409 |
| `GET /api/v1/conversations/{id}/turns/{turn}` | the turn |
| `GET /api/v1/conversations/{id}/events` | SSE, `turn.updated` events with the turn; resume with `Last-Event-ID` or `?after=` |
| `GET /api/v1/conversations/{id}/turns/{turn}/audio` | `audio/wav` (24 kHz mono), single `Range`; 409 before `ready`, 410 after retention |
| `GET /api/v1/conversations/{id}/turns/{turn}/timings.json` | follow-along timings, `parley.timings/v1` |
| `POST /hooks/voice-lab` | voice-lab's webhook, Standard Webhooks signature |
| `GET /healthz` | no token |

Turn states: `thinking` → `speaking` → `ready`, or `failed` with `error.code`
(`agent_failed`, `agent_refused`, `agent_unreachable`, `speech_refused`,
`speech_failed`, `speech_timeout`, `internal_error`).

## Configuration (not dev mode)

Every secret is a file; nothing secret is in the environment or Git.

| Variable | |
| --- | --- |
| `PARLEY_TOKEN_FILE` | the app's bearer token (P1; Pocket ID replaces it in P2). Required. |
| `PARLEY_DATA_DIR` | database, audio and timings (default `state`) |
| `PARLEY_AGENT` | `openclaw` (default) or `fake` |
| `PARLEY_OPENCLAW_URL`, `PARLEY_OPENCLAW_TOKEN_FILE`, `PARLEY_OPENCLAW_AGENT_ID` | the gateway's `/v1/responses` |
| `PARLEY_VOICELAB_URL`, `PARLEY_VOICELAB_TOKEN_FILE` | the speech API and the caller's bearer (P2: Pocket ID client credentials) |
| `PARLEY_WEBHOOK_SECRET_FILE`, `PARLEY_PUBLIC_URL` | the `whsec_` secret and the relay's own URL, for the callback |
| `PARLEY_POLL_INTERVAL` | seconds between status polls, the webhook's backstop (default 15) |
| `PARLEY_MAX_SENTENCE_CHARS` | the voice release's one-pass sentence limit, if known |

## Tests

```sh
uv run pytest        # network-free; also run by ../scripts/verify-linux
```
