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
`relay/.parley-dev/` (or `--data-dir`). Options: `--port`, `--host` (several addresses, comma-separated),
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

All `/api/v1` routes take `Authorization: Bearer <token>` (`--dev`: `parley-dev`; deployed: the app's
Pocket ID access token, through the door); errors are `{"error": {"code", "detail"}}`, `401` for a
missing or bad token (`unauthorized`, `invalid_token`, `token_expired`) and `403` for one that may not use
the relay (`forbidden`, `not_through_door`).

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
| `POST /api/v1/devices` `{token, environment}` | register the phone for push: `token` is the APNs device token in hex, `environment` `sandbox` (or `development`, an Xcode debug build) or `production` (default `PARLEY_APNS_ENV`). 201 the device, 200 when that token was registered already (its environment updated); the answer is `{id, environment, created_at, updated_at, last_push_at, push}` and never holds the token |
| `GET /api/v1/devices` | `{devices, push}`: `push` is whether the relay can send pushes now (false without an APNs key: the app follows its event stream) |
| `DELETE /api/v1/devices/{id}` | 204; 404 for an unknown id |
| `POST /hooks/voice-lab` | voice-lab's webhook, Standard Webhooks signature, no token; `503 webhook_not_configured` until the secret file is placed; a body over 64 KiB is `413` |
| `GET /healthz` | no token |

Turn states: `thinking` → `speaking` → `ready`, or `failed` with `error.code`
(`agent_failed`, `agent_refused`, `agent_unreachable`, `agent_unconfigured`, `speech_refused`,
`speech_failed`, `speech_timeout`, `internal_error`).

## Configuration (not dev mode)

Every secret is a file, read when it is needed: a file placed or rotated on
the host takes effect without a restart, and a file that is not there yet
leaves that integration off (the relay still starts and answers `/healthz`).
Nothing secret is in the environment, the logs or Git. At start-up the relay
logs one line naming which integrations are on and whether each secret file is
present, never a value. The stack (`deploy/stack/compose.yaml`) sets these;
its secret files are in `/run/secrets`.

| Variable | |
| --- | --- |
| `PARLEY_DATA_DIR` | database, audio and timings (default `state`; the stack: `/data`) |
| `PARLEY_OIDC_ISSUER` | the app's sign-in, Pocket ID (`https://id.colobus-stargazer.ts.net`). Required |
| `PARLEY_OIDC_AUDIENCE` | the bearer's audience, comma-separated (default `parley-ios`) |
| `PARLEY_OWNER_SUBJECT` | the owner's Pocket ID user id: the only subject the relay serves. Required |
| `PARLEY_TRUSTED_PROXY` | the door's upstream address(es); `/api/` from any other peer is `403` (the stack: `10.253.92.10`) |
| `PARLEY_AGENT` | `openclaw` (default) or `fake` |
| `PARLEY_OPENCLAW_URL` | the gateway (`https://openclaw.colobus-stargazer.ts.net`); `/v1/responses` |
| `PARLEY_OPENCLAW_TOKEN_FILE` | the gateway's password (password mode, sent as a bearer): `/run/secrets/openclaw-gateway-token` |
| `PARLEY_OPENCLAW_AGENT_ID` | a dedicated OpenClaw agent (optional) |
| `PARLEY_VOICELAB_URL` | the speech API (`https://voice-lab.colobus-stargazer.ts.net`). Required |
| `PARLEY_VOICELAB_CLIENT_ID` | the relay's Pocket ID client, `parley-relay` (client credentials) |
| `PARLEY_VOICELAB_CLIENT_SECRET_FILE` | its secret: `/run/secrets/voicelab-client-secret` |
| `PARLEY_VOICELAB_TOKEN_FILE` | instead of the two above, a static bearer (testing by hand) |
| `PARLEY_WEBHOOK_SECRET_FILE` | voice-lab's `whsec_` webhook secret: `/run/secrets/voicelab-webhook-secret` |
| `PARLEY_PUBLIC_URL` | the relay's own URL, for the callback (`https://parley.colobus-stargazer.ts.net`); with the webhook secret file set, every speech request carries `callback_url` |
| `PARLEY_APNS_KEY_FILE` | the APNs auth key (`.p8`): `/run/secrets/apns-key.p8`. Optional: push is off until it and the two ids are set |
| `PARLEY_APNS_KEY_ID`, `PARLEY_APNS_TEAM_ID` | the key's id and the Apple Developer team id (not secret) |
| `PARLEY_APNS_TOPIC` | the app's bundle id (default `com.scshafe.parley`) |
| `PARLEY_APNS_ENV` | `sandbox` (default; `development` is the same) or `production`, for a device that registers without an environment |
| `PARLEY_POLL_INTERVAL` | seconds between status polls, the webhook's backstop (default 15) |
| `PARLEY_MAX_SENTENCE_CHARS` | the voice release's one-pass sentence limit, if known |

How the app's requests are checked: the module docstring of
`src/parley_relay/auth.py`. `parley-relay --dev` ignores all of this and takes
one static bearer, the public placeholder `parley-dev`, so it listens only on
loopback (`--host` must be `localhost`, `127.0.0.1` or `::1`). It is for the
relay's own tests, trying a turn by hand, and the app's UI tests in CI; the app
itself takes no static token.

## Tests

```sh
uv run pytest        # network-free; also run by ../scripts/verify-linux
```

One opt-in live test checks the OpenClaw gateway's `/v1/responses` contract
(OpenClaw 2026.9.2, password mode), and is skipped unless both variables are
set. On the PC, once the endpoint is enabled and the relay's password file is
placed, the password is piped in and never written elsewhere:

```sh
sudo cat /srv/stacks/parley/state/secrets/openclaw-gateway-token \
  | PARLEY_LIVE_OPENCLAW_URL=https://openclaw.colobus-stargazer.ts.net \
    PARLEY_LIVE_OPENCLAW_TOKEN_FILE=/dev/stdin \
    uv run pytest -s tests/test_openclaw_live.py
```

`PARLEY_LIVE_OPENCLAW_AGENT_ID` picks a dedicated agent. The test prints which
response shape the gateway sent (`output_text` or `output[].content[]`).
