# Parley: design

Design, 2026-10-15. Status: **proposed**, for the owner's review. The brief is
[brief.md](brief.md). Open decisions are at the end; nothing is built yet.

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

- **Recommended: a small voice-lab change.** Add each segment's character range (`text_start` and `text_end`) to its status and its `segment.ready` event. voice-lab's job runner already splits the text, so it knows these ranges.
- **Fallback:** the relay repeats voice-lab's documented splitting rule. This works, but it breaks silently if voice-lab ever changes the rule.

**Word level, in two steps.**

- **P1, estimated.** Within each sentence, a word's time is proportional to its share of the sentence, weighted by syllables, with pauses added for punctuation. This is good enough to follow along, and costs nothing.
- **P3, aligned.** Forced alignment of each segment's audio against its known text, in the relay on CPU. A CTC aligner, for example torchaudio's MMS forced aligner, places each word to within tens of milliseconds. The text is known, so this is alignment, not recognition, and it does not mishear words. The result has the same format as P1, so the app does not change.

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
| P0 | This design, the decisions below, and the project set up: repository, `agent-parley`, picker. | The owner's answers. |
| P1 | The relay pipeline with fakes. The app: conversations, composer, reader-player with estimated word timings, polling instead of push. | `[verify]` green; the app in the simulator against a stub relay. |
| P2 | Real integrations: the OpenClaw adapter, the voice-lab caller and webhook, APNs push, the Pocket ID sign-in, the relay deployed. Owner steps: register the voice-lab caller and the Pocket ID clients, place the APNs key, enable OpenClaw's HTTP endpoint. | One real turn on the phone: a notification, the owner's voice, highlighting in sync. |
| P3 | Forced alignment for word timings, plus the voice-lab segment-range change (a voice-lab PR by its agent). | Highlight drift under 100 ms on 20 sample replies. |
| P4 | Play from the first sentence (voice-lab segment SSE). Voice input with on-device speech recognition. Conversation search. | |

## Decisions (owner)

| Id | Question | Recommendation |
| --- | --- | --- |
| P-Q1 | **Apple Developer Program.** Push notifications (APNs) need a paid membership, $99 a year. Free provisioning has no push, and its builds expire after 7 days. tastemaker's plan already includes enrolling an organization (its D8). | Enroll now as an individual, so this can be built and installed without waiting for tastemaker's organization (legal entity, D-U-N-S). The app can move to the organization later. |
| P-Q2 | **Public (free software) or private repository.** | **Public.** It matches your stated plan of a free iOS app, and gives free macOS CI so the PC's agent can build and test the iOS app. Nothing secret lives in the repository. It goes public after the publication screen (infra `docs/platform/repo-publication-screen-2026-10-05.md`). It starts private until then. |
| P-Q3 | **Fork OpenClaw, or use it as is behind an adapter.** | Use it as is, with the adapter (above). |
| P-Q4 | **Where the relay runs.** | On the PC, next to voice-lab and OpenClaw's sandbox. |
| P-Q5 | **Retention** of conversation text and audio on the relay. | Text kept indefinitely; audio 30 days on the relay and 7 days cached on the phone. voice-lab's own audio retention (7 days) is separate. |
| P-Q6 | **The voice-lab segment-range change** (P3). | Yes: one PR in voice-lab, made by its agent. |
| P-Q7 | **Name.** | "Parley": a conversation, taken in turns. Easy to change before the repository goes public. |
