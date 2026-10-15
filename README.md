# Parley

Talk with your agent in turns, and hear it answer in your own voice. Parley is
an iOS app and a small relay server: a turn goes to an OpenClaw-like agent
with instructions to answer in a style made for speech; the reply is spoken by
the owner's voice-lab voice release; the phone gets a notification and plays
the reply with follow-along highlighting.

- The owner's brief: [docs/brief.md](docs/brief.md)
- The design: [docs/DESIGN.md](docs/DESIGN.md) (and its [P1 build decisions](docs/DESIGN.md#p1-build-decisions))

## Layout

- `relay/`: the relay (Python, uv, Starlette, SQLite). See [relay/README.md](relay/README.md).
- `ios/`: the app. `ios/ParleyKit` is its logic as a Swift package. `ios/Parley` is the SwiftUI app and `ios/ParleyUITests` holds its UI tests. `ios/project.yml` is the XcodeGen spec for the Xcode project.

## Run it locally

The relay in dev mode runs the whole turn flow on one machine. It uses a fake agent and a fake voice-lab that makes synthetic tones, never speech:

```sh
cd relay
uv run parley-relay --dev          # http://127.0.0.1:8765, token parley-dev
```

The app is built on a Mac with Xcode 26:

```sh
brew install xcodegen              # CI pins 2.46.0
xcodegen generate --spec ios/project.yml
open ios/Parley.xcodeproj          # run on an iPhone simulator
```

In the app's settings, the relay is `http://127.0.0.1:8765` and the token is `parley-dev`.

## Build and test

```sh
./scripts/verify-linux
```

This is the repository's one verify command (`dev.toml [verify]`). It runs shell syntax checks, the repository's own tests, and the relay's tests (uv, no network).

CI (`.github/workflows/ci.yml`) runs it on Linux. On `macos-26` it also builds and tests the iOS app:

1. `swift test` runs ParleyKit's tests.
2. XcodeGen generates the project.
3. `parley-relay --dev` starts on the runner.
4. `xcodebuild test` runs the UI tests on an iPhone simulator against that relay.

The test results, with screenshots, are kept as the run's `ios-test-results` artifact.
