# parley agent notes

- Two parts: `relay/` (the server, Python) and `ios/` (the SwiftUI app). The
  app talks only to the relay; the relay alone talks to the agent (OpenClaw)
  and to voice-lab.
- The brief, `docs/brief.md`, is fixed; the design is `docs/DESIGN.md`.
- voice-lab's speech API speaks only the owner's own voice release; never
  wire in another voice or TTS service. Its contract is voice-lab
  `docs/SPEECH_API.md`.
- Push payloads carry ids only, never reply text.
- iOS builds need Xcode on macOS: this PC cannot build `ios/`.
