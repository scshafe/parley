# Parley: design

Design, 2026-10-15. Status: **accepted** (owner, 2026-10-15: every
recommendation below). The brief is [brief.md](brief.md). P1 is built (2026-10-15): see
[P1 build decisions](#p1-build-decisions).

## The shape

```
iPhone (Parley app) ──tailnet──► parley-relay ──► agent (OpenClaw gateway, /v1/responses)
        ▲                            │
        │ push (APNs)                ├──► voice-lab speech API (Cole's voice release)
        └────────────────────────────┤        └─ webhook: speech.succeeded ─┐
                                     │◄──────────────────────────────────────┘
                                     └─ aligns words to audio, stores the turn, sends the push
```

Two parts, one repository:

- **`relay/`, the server.** It owns conversations and the pipeline: user turn → agent → speech → alignment → push. It is the only thing that talks to the agent and to voice-lab. It is a tailnet service, like the fleet's other apps.
- **`ios/`, the app.** SwiftUI. It holds a list of conversations, a composer, push handling, and the player with follow-along text. It talks only to the relay, so the agent behind it can change without an app release.

## Not a fork of OpenClaw (recommended)

OpenClaw's gateway already serves an OpenAI-compatible HTTP surface,
`POST /v1/responses` and `/v1/chat/completions`. It is off by default; when
enabled, a request runs as a normal gateway agent run, with the same
routing, tools and memory as any other channel
([docs](https://docs.openclaw.ai/gateway/openai-http-api)). The relay calls
that surface as an ordinary client:

- **The voice style** goes in as the system or instructions message on every turn, and can also live in a dedicated OpenClaw agent (a `voice` agent id with its own workspace `AGENTS.md`). OpenClaw itself does not change.
- **Conversation continuity** uses OpenClaw's own session, keyed per Parley conversation.
- **One adapter interface** in the relay: `send_turn(conversation, text) → reply text`. OpenClaw is the first adapter; Hermes, or a plain model API, can be added later.

A fork would mean carrying OpenClaw's fast-moving gateway: it ships often, and
its plugin API changed in 2026. All it would gain is a place for the style
instructions, which the relay can already send. OpenClaw's own iOS app is a
"node" that lends the phone's camera, microphone and location to the gateway.
That is a different product from this one, so its code is not a useful
starting point either.

**Caution:** the gateway's HTTP bearer token is an operator credential for
the whole gateway, not a narrow scope. The relay holds it as a secret. The
phone never sees it.

## A turn, step by step

1. **The phone sends the turn.** `POST /api/v1/conversations/{id}/turns` with `{text, client_turn_id}`. The client turn id makes a retry safe.
   - Text is typed, or dictated with iOS's own dictation.
   - The relay answers `202` with the turn in state `thinking`.
2. **Agent.** The relay calls the adapter with the conversation's history handle and the style instructions. It stores the reply text, and the state becomes `speaking`.
3. **Speech.** The relay posts the reply to voice-lab's `POST /api/v1/speech` with:
   - an `idempotency_key` of `turn-<id>`;
   - a `client_ref` of `<conversation>/<turn>`;
   - its webhook as the `callback_url`.

   voice-lab's limit is 2,000 characters per request. A longer reply is split at a sentence boundary into several jobs, played back to back. The style rules aim to keep replies well under the limit.
4. **Done.** voice-lab's `speech.succeeded` webhook arrives (Standard Webhooks, signature checked). As a backstop, the relay also polls the job.
   - The relay fetches the segments and computes the follow-along timings (next section).
   - It stores `reply.wav`, which it can transcode to AAC for the phone, plus `timings.json`.
   - The state becomes `ready`.
5. **Notify.** The relay sends an APNs push. The payload carries only the conversation and turn ids and a fixed alert ("Reply ready"), never the reply text: pushes pass through Apple.
6. **Listen.** Tapping the push opens the turn. The app downloads the audio and timings, plays them, and highlights along.

Each state change is also published on a per-conversation event stream (SSE),
so an open app updates live without waiting for a push.

**Latency, roughly.** The agent takes seconds to minutes. Then voice-lab runs:
F5-TTS renders at about 0.7× real time on the PC's GPU, plus up to 20 s for a
cold start. A 30-second reply is therefore ready about 20–40 s after the agent
finishes. Later, the app can start playing as soon as the first sentence is
rendered, using voice-lab's per-segment SSE (phase P4).

## Answers written for speech: the style rules

The rules go into the instructions on every turn. Each one has a reason:

- **Prose only.** No markdown, lists, tables, code blocks, URLs or emoji. They read badly aloud, and they make the shown text drift from the spoken words.
- **Short and plain sentences.** voice-lab renders sentence by sentence and splits after `.`, `!` and `?`. Very long sentences get split at commas and sound clipped.
- **Spell out what a voice can't say:** symbols, units, abbreviations, and numbers where they would be ambiguous.
- **Keep it short:** about 60–150 words unless asked for more, and never more than 1,800 characters. This keeps a reply in one speech job and gets it to the ear faster.
- **For things that need a screen** (a link, a code snippet, a list), the agent says so in a sentence. The detail goes in an optional "attachment" block that the relay strips from the spoken text and the app shows below the reply. The spoken text and the shown text are therefore always the same words, which the highlighting needs.

As a backstop, the relay also cleans up whatever slips through: it strips
markdown and turns bare URLs into "a link". It records every change, so the
shown text matches what was spoken.

## Follow-along highlighting

**Sentence level, exact.** voice-lab renders one segment per sentence and
reports each segment's `duration_ms`, so the start and end time of every
sentence is known exactly. The relay needs to know which characters of the
text each segment spoke. voice-lab's segment records do not include their
text today. Two ways to get it:

- **Done (voice-lab #110, 2026-10-19): a small voice-lab change.** It adds each segment's character range (`text_start` and `text_end`) to its status and its `segment.ready` event. voice-lab's job runner already splits the text, so it knows these ranges.
- **Fallback, kept for segments rendered before #110 (their ranges are null):** the relay repeats voice-lab's documented splitting rule. This works, but it breaks silently if voice-lab ever changes the rule. The offsets are Unicode code points into the text the job received, which are Python's string indices, so the relay needs no conversion; the app already indexes by Unicode scalar.

**Word level, in steps.**

- **P1, estimated.** Within each sentence, a word's time is proportional to its share of the sentence, weighted by syllables, with pauses added for punctuation. This costs nothing, but live F5 segments open with 0.9–1.9 s of silence and end on their last word, so the highlight ran about a second ahead (measured 2026-10-17 on three live replies against a CTC alignment: mean error 572–1,057 ms).
- **P2, measured (current).** The relay reads the reply's loudness in 10 ms frames and places each sentence's words in the speech it hears. It chooses which silences are the pauses between words: long ones always are, and they go at punctuation wherever possible. Same three replies: mean error 84–120 ms, worst word 364 ms, under 40 ms of CPU. `"source": "measured"`; with no usable audio it falls back to P1. The app also allows for the audio route's output latency (about 0.2 s on AirPods).
- **P3, aligned (decided against, 2026-10-19).** The owner skipped it: measured timing is good enough, so there is no forced alignment and no torch. voice-lab's segment text ranges (voice-lab #110) are used (see above). What this step was: forced alignment of each segment's audio against its known text, in the relay on CPU. A CTC aligner, for example torchaudio's MMS forced aligner, places each word to within tens of milliseconds. The text is known, so this is alignment, not recognition, and it does not mishear words. The result has the same format as P1, so the app does not change.

`timings.json` holds an entry for each word, with its character range in the
shown text and its start and end time. Sentence boundaries are marked too.

**In the app,** an `AVAudioPlayer` with a display-link clock highlights the
current word and tints the current sentence. Tapping a word seeks to it. The
player also offers speeds from 0.75× to 1.5×, lock-screen controls through
`MPNowPlayingInfoCenter`, and background audio.

## Network, identity and secrets

- **Tailnet only.** The relay is a fleet app behind the usual door. The phone reaches it through the Tailscale iOS app, the way it reaches the fleet's web apps today. Nothing is exposed to the internet.
- **Signing in.** The app signs in with Pocket ID: an OIDC authorization-code flow with PKCE, through `ASWebAuthenticationSession`, as a public client. The door checks the bearer token, and the relay sees the owner as the only user.
- **The relay is a voice-lab speech caller.** It gets its own Pocket ID confidential client, using `client_credentials`. voice-lab's configuration registers a caller, `parley`, with its webhook URL prefix, which voice-lab's docs anticipate as "the agent server".
- **Secrets.** Each is a root-only file on the relay's host, never in Git or the image:
  - the OpenClaw gateway token;
  - the Pocket ID client secret;
  - the voice-lab webhook secret;
  - the APNs key, a `.p8` file.
- **Outbound connections:** the relay connects to the OpenClaw gateway, to voice-lab, and to `api.push.apple.com:443` for APNs.

## Where it runs

- **voice-lab** runs on the PC.
- **OpenClaw** is moving into a PC sandbox (sandboxes S7). The relay reaches it through a door or a per-sandbox grant (S4 pattern).
- **Recommended: the relay on the PC too,** as an app-owned stack deployed by the runner lane. The voice path then never leaves the machine.
- **Alternative: the production laptop,** with the other apps. The cost is a tailnet hop to voice-lab and OpenClaw, and the laptop has no GPU for later alignment work (alignment runs on CPU anyway).

Until OpenClaw's S7 move happens, the relay can point its adapter at the
Mini's gateway, `openclaw.<tailnet>`, which is reachable today.

## The iOS app

- SwiftUI and Swift concurrency, targeting the current iOS release, iPhone first.
- **Screens:**
  - conversations;
  - a conversation as a list of turns, each showing its state (thinking, speaking, ready) and a play button;
  - the reader-player;
  - settings: the relay URL, sign-in, and notification permission.
- **Data:** a small local cache (SwiftData) of turns, text, timings and recent audio, for listening offline. The relay holds the full record.
- **Tests:**
  - unit tests for the timing math and the highlight cursor;
  - snapshot tests for the reader;
  - UI tests against a stub relay.
- **Builds and CI:** iOS builds need Xcode on macOS. The PC and its agent cannot build iOS. GitHub's macOS runners are free for public repositories, so a public repository gets real iOS builds and tests in CI. A private one depends on building locally on the Air. See decision P-Q2.

## The relay

- **Language: Python** (uv, FastAPI or Starlette, SQLite with WAL). Forced alignment (torchaudio) is Python, and voice-lab's own client code is Python. Small and single-tenant.
- **Storage:** conversations, turns, their states and events in SQLite. Audio and timings are files under the stack's state volume, kept for N days (decision P-Q5).
- **The pipeline is a small job runner,** with every step idempotent: agent call, speech request, webhook or poll, alignment, push. A restart resumes each turn from its last recorded state.
- **Tests run without the network,** against fakes of OpenClaw, voice-lab and APNs. A contract test checks the voice-lab fake against `SPEECH_API.md`'s examples.

## Phases

| Phase | What | Gate |
| --- | --- | --- |
| P0 | This design, the decisions below, and the project set up: repository, `agent-parley`, picker, publication. | Done 2026-10-15. |
| P1 | The relay pipeline with fakes. The app: conversations, composer, reader-player with estimated word timings, polling instead of push. | Done 2026-10-15: `[verify]` green; CI's UI tests run the app in the simulator against `parley-relay --dev`. |
| P2 | Real integrations: the OpenClaw adapter, the voice-lab caller and webhook, APNs push, the Pocket ID sign-in, the relay deployed. Owner steps: register the voice-lab caller and the Pocket ID clients, place the APNs key, enable OpenClaw's HTTP endpoint. | One real turn on the phone: a notification, the owner's voice, highlighting in sync. |
| P3 | Forced alignment for word timings, plus the voice-lab segment-range change (a voice-lab PR by its agent). | **Skipped by the owner, 2026-10-19:** measured timing (P2) is good enough. The segment-range change (voice-lab #110) landed and is used. |
| P4 | Play from the first sentence (voice-lab segment SSE). Voice input with on-device speech recognition. Conversation search. | Built: [Playing from the first sentence](#playing-from-the-first-sentence), [the Action Button and dictation](#the-action-button-and-dictation) and [conversation search](#conversation-search). |

## P1 build decisions

Details the P1 build settled (2026-10-15). Each can change; the code is the
reference.

**The relay**

- **Stack.** Starlette, uvicorn and httpx on Python 3.12 (`relay/.python-version`), locked by `uv.lock`; SQLite in WAL mode through the standard library. `parley-relay --dev` runs everything locally (below).
- **API.** As in the relay's [README](../relay/README.md#api). Errors are `{"error": {"code", "detail"}}`. A turn retry with the same `client_turn_id` and text answers `200` with the same turn; another text answers `409 client_turn_conflict`.
- **Events.** One SSE stream per conversation. Each `turn.updated` event carries the whole turn. Events are stored, so `Last-Event-ID` (or `?after=`) resumes a stream. The relay closes a stream after 10 minutes, and the app reconnects. When the stream is down, the app polls while a turn is unfinished.
- **Auth for P1.** One static bearer token from `PARLEY_TOKEN_FILE`. The relay refuses to start without it, except in `--dev`, which uses the public placeholder `parley-dev` and listens on `127.0.0.1`.
- **Pipeline details.**
  - Speech requests use the idempotency key `turn-<turn>-<n>` and the `client_ref` `<conversation>/<turn>`, plus `/<n>` when there are several jobs.
  - The webhook wakes the turn. A status poll every 15 seconds is the backstop. A turn gives up after 30 minutes.
  - Retryable errors (`gpu_busy`, `queue_full`, `429`, network errors, a busy agent) are retried 5 times with exponential backoff, and `Retry-After` is honoured.
  - The agent is called once at a time per conversation, in turn order.
  - The agent call is the one step that is not idempotent: a relay that restarts during it asks the agent again. The reply is stored only once it has arrived.
- **Webhook.** A webhook for an unknown job answers `410`, so voice-lab stops retrying. One that beats the relay's own record of the job finds the turn through its `client_ref`.
- **Audio.** The relay serves WAV (24 kHz, mono, 16-bit), as voice-lab makes it, with `Range`. A 30-second reply is about 1.4 MB. There is no AAC transcode in P1, because the relay has no ffmpeg. A multi-job reply is joined into one file.
- **Style and cleanup.**
  - The style instructions live in `relay/src/parley_relay/prompts/style-v1.md`. Each turn records its `style_version`.
  - The attachment block is written `<attachment>…</attachment>`.
  - Links that the cleanup removes from the spoken text are listed in the attachment, under "Links:".
  - Every cleanup change is returned with the turn (`cleanup`).
- **voice-lab's sentence rule, where SPEECH_API.md §7 leaves room** (`sentences.py`):
  - A fragment under 12 characters is measured as the stripped text built up so far.
  - A short fragment at the very end, with no next sentence, is rendered on its own.
  - The one-pass length limit depends on the voice release's reference clip, which the relay cannot see. It is a setting, `PARLEY_MAX_SENTENCE_CHARS`, unset by default.
  - When the split does not give one sentence per segment, the job's text becomes one timed span and `exact_sentences` is `false`. Reported `text_start` and `text_end` (voice-lab #110) are used first inside `segment_ranges()`; the rule applies only when any segment's range is missing or null.
- **Assumed until checked against a real voice-lab (P2).** A refusal body is `{"code", "detail"}` at the top level. The client also reads `{"error": {…}}`. (P2: wrong; see [P2 build decisions](#p2-build-decisions-the-relay).)
- **OpenClaw adapter.**
  - It sends `model: "openclaw/<agent>"`, plus `x-openclaw-agent-id` when an agent id is set.
  - It sends `user: "parley:<conversation>"` for the session, and the style text as `instructions`.
  - It reads `output_text`, or else the `output_text` parts of `output[].content[]`.
  - It has been tested only against a local fake (P2: plus an opt-in live test; see [P2 build decisions](#p2-build-decisions-the-relay)).
- **Push payload.** `{"aps": {"alert": "Reply ready", "sound": "default"}, "conversation_id", "turn_id"}`. P1 records the payload and does not send it (P2 sends it through APNs).
- **Retention.** An hourly sweep deletes audio older than 30 days. Text and timings stay (P-Q5).

**`timings.json` (`parley.timings/v1`)**

- `{format, source, offsets, duration_ms, text_length, turn_id, exact_sentences, sentences[], words[]}`.
- A sentence is `{index, char_start, char_end, start_ms, end_ms}`. A word is the same, plus the index of its `sentence`.
- Offsets are half-open ranges of Unicode scalars (code points) in the shown text.
- A word's range leaves out the punctuation around it.
- The weights, in syllable units: a 0.3-syllable lead-in, a 1.0 pause after `, ; : —`, a 1.6 pause after a mid-sentence `. ! ?`, and a 1.2-syllable tail after the last word.

**The app**

- **Targets and versions.** iOS 26.0, iPhone only, built with Xcode 26.6 in Swift 5 language mode.
- **ParleyKit.** The logic lives in `ios/ParleyKit`, a Swift package (iOS 18 and macOS 15) tested with `swift test`. It holds the models and client, the SSE parser, timings, the highlight cursor, the playback machine and the speeds.
- **The project.** The Xcode project is generated from `ios/project.yml` by XcodeGen 2.46.0, installed in CI by checksum. The `.xcodeproj` is not committed.
- **The reader.** The reply is laid out as word tokens in a flow layout, so a tap seeks to a word.
  - The heard word is filled with the accent colour, and its sentence is tinted.
  - A word stays lit through the pause after it.
  - The clock is `AVAudioPlayer.currentTime`, sampled on a `CADisplayLink`.
  - Leaving the reader pauses playback. The lock screen controls a reply while it plays in the background.
- **Settings and cache.**
  - The relay URL is kept in UserDefaults (P1 also kept a dev token in the Keychain; the login screen removed it, see P2 build decisions: the app).
  - SwiftData caches conversations, turns and timings. Reply audio is cached in Caches for 7 days (P-Q5).
  - `NSAllowsLocalNetworking` permits plain `http` for a dev relay on the local network or in the simulator.
- **Notifications.** The settings screen asks for notification permission. Push itself is P2 (below).

**CI.** The `verify` job (`ubuntu-latest`) runs `./scripts/verify-linux`, which includes the relay's tests through uv 0.12.21. The `ios` job runs on `macos-26`:

1. `swift test` for ParleyKit.
2. XcodeGen generates the project.
3. `parley-relay --dev` starts on the runner.
4. `xcodebuild test` runs on an iPhone 17 simulator (iOS 26.5). The UI tests send a turn, wait for `ready`, and check that the highlight advances with the audio.

The xcresult, with its screenshots, and the relay's log are kept as the `ios-test-results` artifact.

## P2 build decisions: the relay

What the P2 build settled for the relay (2026-10-16). Each can change; the code
is the reference. The app's P2 work is recorded separately.

**Deploy.**

- **The lane.** `dev.toml [deploy]`: the runner lane, app layout, on the PC, node `parley` behind the Pocket ID door, verified on GitHub's hosted runner (the repository is public). `.github/workflows/deploy.yml` is scshafe-dev's, with the same uv setup as `ci.yml`. A merge to `main` deploys once the owner has registered the PC's `parley-prod` runner; until then the deploy job waits for a runner.
- **The image.** The root `Dockerfile` builds `relay/` with uv 0.12.21 (`uv sync --frozen --no-dev`) on the fleet's pinned `python:3.12-slim`, into `/opt/venv`. The build backend is uv's own, pinned (`uv_build==0.12.21`, no dependencies), so nothing the build fetches is unpinned. It runs as uid:gid `10001:10001`, never root. The healthcheck is the venv's Python (`urllib`), because the image has no curl. `.dockerignore` keeps the iOS app and local state out of the build.
- **The stack** (`deploy/stack/`). voice-journey's door layout: `ts-parley` (Serve on 443) → `oauth2-proxy` v7.15.5 → the relay, on the subnets `10.253.92.0/29` (door) and `10.253.92.8/29` (upstream), plus `egress`. Every image is pinned by digest, or is the relay's own pinned build.
  - The door accepts the app's Pocket ID access token as a bearer (an extra JWT issuer whose audience is `parley-ios`) and passes it through unchanged. It sets `X-Forwarded-User` after stripping any copy the caller sent. `/api/` answers `401`, never a login redirect.
  - `GET /healthz` (the deploy witness) and `POST /hooks/voice-lab` (signature-checked by the relay) pass without a session.
  - For the event stream: a 100 ms flush interval and a 60 s upstream timeout. The relay ends a stream after 10 minutes, and the app reconnects.
  - The relay listens on its upstream address and on loopback (`--host 10.253.92.11,127.0.0.1`), never on `egress`. It reaches the id node, voice-lab and the OpenClaw gateway through the host's tailscaled, by `extra_hosts` (`ID_TAILNET_IP`, `VOICE_LAB_TAILNET_IP`, `OPENCLAW_TAILNET_IP`). It reaches APNs by public DNS.
  - The root is read-only, with a 64 MB `/tmp` tmpfs. `state/data` is mounted read-write at `/data`, and `state/secrets` read-only at `/run/secrets`.
- **Secret files** (`state/secrets`, each `0600` and owned by `10001`): `openclaw-gateway-token`, `voicelab-client-secret`, `voicelab-webhook-secret` and, optionally, `apns-key.p8`. Every service binds the directory read-only, so the deploy never creates it: the owner makes it (`0700`, owned by `10001`) before the first deploy, or infra's validator refuses the deploy (V-05).
- **`stack.toml`.** The health path is `/healthz`. A rollback rolls back only the relay. The backup holds `state/data`, `state/secrets` and `.env`. `[env]`:
  - required: `TS_AUTHKEY`, `OIDC_CLIENT_ID`, `OIDC_CLIENT_SECRET`, `ID_TAILNET_IP`, `VOICE_LAB_TAILNET_IP`, `OPENCLAW_TAILNET_IP` and `PARLEY_OWNER_SUBJECT`;
  - generated: `OAUTH2_PROXY_COOKIE_SECRET`;
  - owner, optional: `PARLEY_APNS_KEY_ID`, `PARLEY_APNS_TEAM_ID`, `PARLEY_APNS_ENV` and `PARLEY_OPENCLAW_AGENT_ID`.
- **The database in a backup.** The stack's backup is a byte copy (tar) of `state/data`, and the live SQLite database is in WAL mode, so its copy can be torn. The relay therefore keeps a consistent copy, `state/data/backup/relay.sqlite3`, made with SQLite's online backup API into a temporary file and renamed into place. It is refreshed every 5 minutes when anything was written, and once more whenever the relay stops (a deploy's or a restart's stop). Audio and timings are written whole (a temporary file, then a rename).
  - **Restoring:** extract the backup, delete `relay.sqlite3`, `relay.sqlite3-wal` and `relay.sqlite3-shm` from `state/data`, and start the relay. A relay that finds no database but finds the copy starts from the copy, and logs that it did.
  - The pre-deploy backup runs while the old relay is still up, so the copy can be up to 5 minutes behind it. infra's rules leave this stack no other route: it has no host binds and no database container. A turn in flight when the copy was taken resumes from its last recorded state (P1's restart rule).

**The app's sign-in at the relay** (`relay/src/parley_relay/auth.py`).

- In real mode, P1's static bearer (`PARLEY_TOKEN_FILE`) is gone. `--dev` keeps only its public placeholder `parley-dev`, and so listens only on loopback; `PARLEY_TOKEN` / `PARLEY_TOKEN_FILE` are gone too. A request to `/api/` must pass three checks:
  - It comes from the door: its peer is `PARLEY_TRUSTED_PROXY`, the door's upstream address.
  - It carries a Pocket ID access token as its bearer: RS256 or ES256, verified against the issuer's JWKS (found through discovery), from `PARLEY_OIDC_ISSUER`, with an audience in `PARLEY_OIDC_AUDIENCE` (`parley-ios`), and inside its lifetime (60 s leeway).
  - Its subject, and the door's `X-Forwarded-User`, are the owner (`PARLEY_OWNER_SUBJECT`). oauth2-proxy v7.15.5 sets `X-Forwarded-User` from `sub`.
- A missing or bad token answers `401`, with `WWW-Authenticate: Bearer`. The codes are `unauthorized`, `invalid_token` and `token_expired`. The app refreshes its token on `token_expired` and signs in again otherwise.
- A good token for someone else, or a request that went around the door, answers `403` (`forbidden`, `not_through_door`). Keys that cannot be fetched answer `503`.
- The keys are kept for an hour. An unknown key id refetches them. Fetches, failed ones included, happen at most once a minute: while Pocket ID is unreachable, the last keys are served on and requests do not wait on a fetch. `jwks_uri` must be https on the issuer's own origin.
- `exp`, `nbf` and `iat` must be finite numbers (JSON parsing accepts `NaN` and `Infinity`).
- Pocket ID's live JWKS (read 2026-10-16) holds one RSA key, 2048 bits, `alg` RS256, and its discovery document lists only RS256. ES256 support is spare.
- `/healthz` and `/hooks/voice-lab` take no token.

**voice-lab as a caller** (`relay/src/parley_relay/oidc.py`, `voicelab.py`).

- The relay's bearer is a client-credentials token for the confidential client `parley-relay`. It is fetched with `client_secret_basic` from the issuer's discovered token endpoint, which must be https on the issuer's own origin before the secret is sent, and reused until 60 s before `expires_in` (or before the JWT's `exp`). A `401` from voice-lab drops the token and retries once with a fresh one.
- A token that cannot be had fails the speech request as `caller_token_unavailable`. It is retried when the provider was unreachable, and not when the client was refused or the secret file is missing.
- **The refusal body**, checked against voice-lab's source (`ApiRefusal`, `src/cole_voice_lab/api/contracts.py`), not yet against a live API: `{"error": "<code>", "detail": "..."}`. P1's assumption was wrong. The client reads this shape first and still accepts P1's two guesses. The fake now answers this shape. A job's own `error` stays `{"code", "detail"}` (`SpeechFailure`).

**Configuration** (`relay/README.md`, "Configuration").

- Every secret is a file, re-read when it changes (`secretfiles.py`). A file placed or rotated on the host takes effect without a restart. A file not there yet leaves that integration off:
  - no gateway password: the turn fails `agent_unconfigured`;
  - no caller secret: speech is refused;
  - no webhook secret: the webhook answers `503 webhook_not_configured`, and polling carries the turn.
- Real mode refuses to start without `PARLEY_OIDC_ISSUER`, `PARLEY_OWNER_SUBJECT` and `PARLEY_VOICELAB_URL`.
- One start-up line names the auth mode, the agent, the speech caller, the webhook and push, and whether each secret file is present. It never shows a value.

**Push and devices** (`relay/src/parley_relay/push.py`; the API in the relay's README).

- **Devices.** The app registers with `POST /api/v1/devices {token, environment}`. `environment` is `sandbox` (or `development`, the entitlement's word for a debug build) or `production`. Registering the same token again answers `200` with the same device and updates its environment. `DELETE /api/v1/devices/{id}` removes a device. `GET /api/v1/devices` lists the devices and says whether push is on (`push`).
  - The token is stored in SQLite, sent only to Apple, and never logged or returned. Logs name device ids only.
- **APNs.** HTTP/2 only (`httpx[http2]`), with token-based auth: an ES256 provider token from the `.p8` key, `{alg, kid}` `{iss: team id, iat}`. It is reused for 50 minutes; Apple's window is 20 to 60.
  - Headers: `apns-topic: com.scshafe.parley`, `apns-push-type: alert`, `apns-priority: 10`, a 24-hour `apns-expiration`, and the turn id as `apns-collapse-id`.
  - The payload is P1's, ids only.
  - Each device's environment picks the host (`api.sandbox.push.apple.com` or `api.push.apple.com`), so a debug build and a release can both be registered.
  - `410` (`Unregistered`) forgets the device. `400 BadDeviceToken` does not: Apple also answers it for a token sent to the other environment's host, so the push is tried once on the other host, the device's environment is updated if that works, and the device is kept either way.
  - A refused provider token (`ExpiredProviderToken`, `InvalidProviderToken`) is renewed and the push retried, at most once per push (not once per device). Any other refusal is logged, and one device's failure never stops the others.
  - `PARLEY_APNS_ENV` accepts `development` as a name for the sandbox, as the API does.
- **Optional, and off today.** Push needs a paid Apple Developer Program membership; the owner has a free Apple ID for now (P-Q1 is pending). Without the key id, the team id or the key file, push is off: the start-up line says so, and so does one log line when the state changes, not once per turn. The relay stays healthy, and the app learns that a turn is ready from its event stream.
  - The key file is read on use, so placing it later turns push on without a restart.
  - A push never fails a turn: a ready turn is marked pushed whatever APNs answers.
- **Tests.** A local HTTP/2 APNs fake (h2, cleartext prior knowledge) checks the provider token's signature, the headers, pruning, renewal and the hosts.

**The OpenClaw adapter, live** (`relay/tests/test_openclaw_live.py`).

- An opt-in contract test of `/v1/responses` against the real gateway (OpenClaw 2026.9.2, password mode: the password is the bearer). It is skipped unless `PARLEY_LIVE_OPENCLAW_URL` and `PARLEY_LIVE_OPENCLAW_TOKEN_FILE` are set. It checks three things:
  - the response's status and where its text is (`output_text`, or the `output_text` parts of `output[].content[]`), and it prints which;
  - that two turns with one `user` (`parley:<conversation>`) share a session;
  - that a wrong password is `agent_refused` and is not retried.
- The password is held in a wrapper whose repr is `<redacted>`, and the adapter keeps the bearer only inside `httpx.Headers`, whose repr masks it. A failing run, even with `pytest -l`, therefore never prints it (checked with a sentinel). `/dev/stdin` as the token file works only with `pytest -s`.
- OpenClaw's docs list `status` `incomplete` (a reply cut at the token limit). The adapter reads its text like a completed one.
- It has been run only against a local stand-in so far. The real run waits for runbook Stage 6 (the endpoint enabled) and Stage 7c (the password file).

## P2 build decisions: the app

Details the P2 build settled for the iOS app (2026-10-16). The code is the reference.

- **Sign-in.** OIDC authorization code with PKCE (S256), as Pocket ID's public client `parley-ios`.
  - The issuer and client id are build settings (`PARLEY_OIDC_ISSUER`, `PARLEY_OIDC_CLIENT_ID`) read from the Info.plist; the endpoints come from the issuer's discovery document.
  - The redirect is `com.scshafe.parley://oauth/callback`, a URL scheme the app registers. The sign-in page opens in an ephemeral `ASWebAuthenticationSession` (no shared cookies, no "wants to sign in" prompt; a passkey works).
  - Scopes `openid profile email offline_access` (`offline_access` only if the issuer lists it).
  - The callback's `state`, its `iss` when present (RFC 9207), and the ID token's issuer, audience and nonce are checked. The ID token's signature is not: it comes straight from the token endpoint over TLS, and its claims only name the account in Settings. The relay's door verifies the access token.
- **Tokens.** The access token, refresh token and ID token are one Keychain item (this device only, after first unlock), updated in place so a failed write keeps the old one. The access token is refreshed a minute before it expires, one refresh at a time, inside a background task so a rotated refresh token is saved even as the app leaves the foreground. A refresh that Pocket ID refuses (400 or 401) signs the app out; a network error does not. A refresh that finishes after a sign-out is dropped.
- **Where the token goes.** The session's access token is sent only over https to a relay host under `PARLEY_RELAY_HOST_SUFFIX` (a build setting, the tailnet's suffix by default); the app refuses any other relay, a plain-http dev relay included. Relay calls follow redirects only within the same scheme, host and port. Discovered endpoints must be https unless the issuer itself is http.
- **Networking with the token (B13).** Every relay call carries the current access token. A 401 is retried once with a fresh token, but a rejection refreshes at most once in 30 seconds: a relay that keeps refusing fresh tokens (a wrong door audience, a dev relay) gets `unauthorized`, not a refresh loop. Audio and timings are downloaded with the token; the player plays the downloaded file. The event stream opens with the current token (retried once after a 401) and reconnects when the sign-in changes or the app returns to the foreground; after a refresh, it uses the new token at its next reconnect.
- **Signing out** forgets the tokens, revokes the refresh token if the issuer's discovery document lists a `revocation_endpoint` (Pocket ID v2.13 lists none, so the token stays valid at Pocket ID until it expires, 30 days for `parley-ios`), and clears the cached conversations, turns and reply audio. The Keychain outlives a deleted app, so the first launch of a new install (no `installed` marker in UserDefaults) clears the app's Keychain items.
- **The login screen.** Until the person is signed in, the app shows a login screen instead of the conversations: the icon and name, the relay's address (prefilled from the build setting `PARLEY_DEFAULT_RELAY_URL`, editable) and **Sign in**.
  - The address is checked first (it parses, is https, and is under `PARLEY_RELAY_HOST_SUFFIX`); a problem is shown under it and nothing is sent.
  - Then the Pocket ID sign-in, then a check that the relay answers (`GET /api/v1/conversations`). If the relay fails, the person stays signed in on the login screen, which says so and offers **Try again** (with the address editable) or **Sign out**.
  - Settings shows the account and **Sign out**, which returns to the login screen, and the relay's address, which is saved only if it passes the same check. An ended session (a refused refresh) also returns to the login screen.
- **No dev token.** The app has no static token: P1's dev-token field, its Keychain item (`relayToken`) and the `PARLEY_DEV_TOKEN` variable are gone. The first launch of a build without it deletes a leftover `relayToken` item once.
- **The UI tests' seam** (`ios/Parley/UITestSeam.swift`). Compiled only into a debug simulator build, and on only with `PARLEY_UI_TESTING=1`: a fake signed-in session in memory whose access token is `PARLEY_UI_TEST_ACCESS_TOKEN` (CI: the dev relay's `parley-dev`), the relay `PARLEY_UI_TEST_RELAY_URL`, plain http allowed to loopback only, and **Sign in** without Pocket ID. `PARLEY_UI_TEST_SIGNED_IN=1` starts signed in; otherwise the tests start on the login screen.
- **Push (B11), opt-in.** A free Apple ID team cannot sign `aps-environment`, so `PARLEY_PUSH` defaults to `NO`: no entitlements, and no call to `registerForRemoteNotifications`. With `PARLEY_PUSH = YES` (a paid team, in `ios/project.local.yml`), `CODE_SIGN_ENTITLEMENTS` points at `ios/Entitlements/Parley-Push.entitlements`, whose `aps-environment` is `development` in every configuration: Xcode's export rewrites it for App Store, TestFlight and ad hoc builds.
  - The environment the device token belongs to comes from the app's embedded provisioning profile at run time: its `aps-environment` `development` is `sandbox`, and no profile (App Store, TestFlight) or a distribution profile is `production`. The simulator is `sandbox`.
  - Once notifications are allowed, the app registers at every launch. It posts `{token, environment}` (the token as hex; `environment` `sandbox` or `production`) to `POST /api/v1/devices`, again when the relay or the sign-in changes. It keeps the device id the relay answers, per relay URL. It deletes that device (`DELETE /api/v1/devices/{id}`) before signing out and when the relay URL changes, while it still has that relay's credentials.
  - A notification tap opens the payload's conversation, then the reader when the turn is ready. A newer tap replaces one still loading. A notification for the conversation on screen shows no banner.
- **Local notifications without push.** A followed turn that becomes ready while the app is in the background, but still running, gets a local notification. It has the same ids and the same fixed text, "Reply ready". On leaving the app with a turn unfinished, the app asks for background time (about 30 seconds) and polls the turn; while a reply plays in the background, the app keeps running. A turn that takes longer than that, with nothing playing, gets no notice until push is on. Once push is registered and the relay says it can push (the registration's `push`), no local notification is sent. The watched turns are cleared when the relay or the sign-in changes, and dropped after 35 minutes (the relay gives up on a turn after 30).

## Playing from the first sentence

Built 2026-10-19, on voice-lab's per-job event stream (`GET /api/v1/speech/{id}/events`: one `segment.ready` per sentence, `Last-Event-ID` resume, a terminal `speech.*` event).

- **The relay follows each job's stream** once its jobs are posted (`Pipeline._stream_segments`), one job at a time, so it holds one of voice-lab's four streams per caller. For each `segment.ready` it fetches the sentence's audio, keeps it as `segments/<n>.wav` (numbered across a reply's jobs) and adds it to the turn's `segments`: `{index, duration_ms, offset_ms, url}`, `offset_ms` being where it starts in the joined reply (the segments are joined with no cross-fade, so the offsets match `reply.wav`). Each addition is a `turn.updated` event, so the app needs no new event type. After a close without a terminal event (voice-lab ends a stream after 10 minutes) it reconnects with `Last-Event-ID`.
- **It is best effort.** A refused stream (`429 too_many_streams`), a network error or a restart only mean the app waits for the whole reply, as before; the turn is never failed by it. After a restart the follower starts again from the first sentence and rebuilds the list. When the turn ends, the relay lets the follower collect the last sentences for up to 10 seconds, because the app may still be playing earlier ones.
- **`GET …/turns/{tid}/segments/{n}/audio`** serves a sentence (WAV, with `Range`), `404 segment_not_found` for one not listed. The retention sweep deletes them with `reply.wav`.
- **No text comes with a segment** (its status and events carry a code-point range per sentence, which the relay does not yet pass on), so streamed playback has no word highlight. The app shows the reply text as before and a **Listen now** button on a speaking turn with at least one sentence. `LivePlayer` downloads the sentences in order and queues them on an `AVQueuePlayer`, and plays on as more arrive. It ends when the turn is no longer speaking and the queue is heard. Opening a ready reply in the reader (or dictating) stops it. A seamless hand-over from live playback to the reader, with highlight and seeking, is not built: the reader starts the whole reply from the beginning.

## Conversation search

Built 2026-10-19. `GET /api/v1/conversations?q=<text>` returns the conversations whose title, or any turn's question or reply text, contains the text (case-insensitive substring, newest first). Each result has a `snippet`: the text around the first match, on one line. An empty or over-200-character `q` is a 422. The relay scans in Python; at one owner's volume that is cheap, and SQLite FTS can replace it if it ever is not. The app's list uses `.searchable`, waits 300 ms after typing, and shows the snippet. Search needs the relay: offline, the cached list is not searched.

## The Action Button and dictation

What the build settled (2026-10-16). The code is the reference.

- **The intent.** `NewConversationIntent` ("New Parley Conversation", `ios/Parley/Intents.swift`), offered through `ParleyShortcuts`, an `AppShortcutsProvider`. That puts it in Settings → Action Button → Shortcut → Parley and in the Shortcuts app.
  - **Decided 2026-10-19: no Control Center control.** The Action Button already works through this App Shortcut, and the owner does not want a widget otherwise.
  - It runs in the app (`supportedModes = .foreground(.immediate)`), with no extension, so the free team's one target is enough.
  - It bumps `AppModel.dictatedConversationRequests`. The root view then does one of three things:
    - while a dictation listens, it sends it ("send now");
    - while one is finishing, it does nothing;
    - otherwise it opens a new conversation that listens with auto-send.
  - Not signed in, the login screen stays.
- **A new conversation has no id yet.** The conversation view makes it at the relay with its first message, so listening starts without waiting on the network. The composer's `+` still creates one at once.
- **When it sends** (`DictationMachine`, ParleyKit, unit tested). With auto-send, the message is sent once some words were heard and the transcript then stays unchanged for `silenceToSend` (2 s). Silence is measured on the transcript, not the audio level, so background noise does not hold it open.
  - **Send**, or the Action Button again, sends at once; with nothing heard, it stops instead.
  - **Cancel** discards.
  - `idleTimeout` (20 s) without a new word, or without any word, stops: nothing is sent with auto-send, and the words stay in the draft without it.
  - On a failure, what was heard stays in the draft.
  - The final transcript (after the engine finalizes) is what is sent.
- **The composer's mic** uses the same machine without auto-send: the words go after what was typed, and wait for **Send** or another tap on the mic.
- **Speech.** iOS 26's `SpeechAnalyzer` (the deployment target is 26.0), on device:
  - `SpeechTranscriber` when `isAvailable` and the locale is supported, else `DictationTranscriber` (punctuation, the short-form hint);
  - volatile results for the live text;
  - the locale's model installed through `AssetInventory` on first use;
  - the microphone's buffers converted to `bestAvailableAudioFormat`.
  - If the analyzer cannot start (no model, the simulator), the app falls back to `SFSpeechRecognizer`, with `requiresOnDeviceRecognition` when the device supports it for the locale.
  - Both need the microphone and speech recognition permissions (`NSMicrophoneUsageDescription`, `NSSpeechRecognitionUsageDescription`). A refusal is shown with where to turn it on.
- **Audio.** Listening stops any reply playback first, then sets the session to `.record` (`.measurement`, other audio ducked) and deactivates it afterwards. The player sets `.playback` again whenever it loads a reply, so its playback and highlighting are unchanged. Leaving the app while listening stops listening and keeps the words.
- **UI tests.** The seam adds `PARLEY_UI_TEST_DICTATION`, a scripted engine that "hears" its words one at a time with no microphone, and `PARLEY_UI_TEST_NEW_DICTATED_CONVERSATION`, which does what the intent does at launch. A real microphone, the permission prompts and the Action Button itself are tested only on a phone.

## Decisions (owner, 2026-10-15: the recommendations accepted)

| Id | Question | Decision |
| --- | --- | --- |
| P-Q1 | **Apple Developer Program.** Push notifications (APNs) need a paid membership, $99 a year. Free provisioning has no push, and its builds expire after 7 days. tastemaker's plan already includes enrolling an organization (its D8). | Enroll now as an individual, so this can be built and installed without waiting for tastemaker's organization (legal entity, D-U-N-S). The app can move to the organization later. |
| P-Q2 | **Public (free software) or private repository.** | **Public.** It matches your stated plan of a free iOS app, and gives free macOS CI so the PC's agent can build and test the iOS app. Nothing secret lives in the repository. It goes public after the publication screen (infra `docs/platform/repo-publication-screen-2026-10-05.md`). It starts private until then. |
| P-Q3 | **Fork OpenClaw, or use it as is behind an adapter.** | Use it as is, with the adapter (above). |
| P-Q4 | **Where the relay runs.** | On the PC, next to voice-lab and OpenClaw's sandbox. |
| P-Q5 | **Retention** of conversation text and audio on the relay. | Text kept indefinitely; audio 30 days on the relay and 7 days cached on the phone. voice-lab's own audio retention (7 days) is separate. |
| P-Q6 | **The voice-lab segment-range change** (P3). | Yes: one PR in voice-lab, made by its agent. |
| P-Q7 | **Name.** | "Parley": a conversation, taken in turns. Easy to change before the repository goes public. |
