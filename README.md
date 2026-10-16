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
- `Dockerfile`, `deploy/stack/`: the relay's image and its stack on the PC, behind the Pocket ID door, at `https://parley.<tailnet>/` (the runner lane, `.github/workflows/deploy.yml`; [P2 build decisions](docs/DESIGN.md#p2-build-decisions-the-relay)).
- `ios/`: the app. `ios/ParleyKit` is its logic as a Swift package. `ios/Parley` is the SwiftUI app and `ios/ParleyUITests` holds its UI tests. `ios/project.yml` is the XcodeGen spec for the Xcode project. `ios/tools/make-app-icon.swift` draws the app icon (light, dark and tinted) into `ios/Parley/Assets.xcassets`; run it on a Mac only to change the icon.

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

In the app's settings, the relay is `http://127.0.0.1:8765` and the dev token (under *Dev relay*) is `parley-dev`. A dev relay does not take a Pocket ID sign-in.

## Install on your iPhone with a free Apple ID

`ios/project.yml` is unsigned, so CI can build it for the simulator. To run the app on a phone, sign it with your own team in a local spec that Git ignores. A free Apple ID (a "personal team") is enough to install and run Parley. It cannot sign push notifications, and its builds stop opening after 7 days.

1. **Add your Apple ID to Xcode:** Xcode → Settings → Accounts → **+** → Apple ID.
2. **Find your Team ID** (10 characters; it is not a secret). Xcode lists every team your accounts belong to, with its ID, name and type ("Personal Team" for a free Apple ID):

   ```sh
   defaults read com.apple.dt.Xcode IDEProvisioningTeamByIdentifier | grep -E 'teamID|teamName|teamType'
   ```

   Or pick your team once under the Parley target's *Signing & Capabilities*; *Development Team* in its build settings then shows the ID. (Reading it from an "Apple Development" certificate is unreliable when you have several.)

   A free team can use the bundle id `com.scshafe.parley` only if no other team has registered it, and it can register at most 10 App IDs in 7 days. If Xcode refuses the id, set another one as `PARLEY_BUNDLE_ID` in your local spec.
3. **Write the local spec** and generate the project from it:

   ```sh
   cp ios/project.local.yml.example ios/project.local.yml   # then set DEVELOPMENT_TEAM
   xcodegen generate --spec ios/project.local.yml
   open ios/Parley.xcodeproj
   ```

   `ios/project.local.yml` includes `project.yml` and adds only `DEVELOPMENT_TEAM` and `CODE_SIGN_STYLE: Automatic`. Generate from it every time; generating from `project.yml` makes an unsigned project again.
4. **Plug the iPhone in** with a cable, unlock it, and tap **Trust** on "Trust This Computer?".
5. **Turn on Developer Mode** on the iPhone: Settings → Privacy & Security → Developer Mode → on. The phone restarts; confirm **Turn On** after it does. The switch appears only once the phone has been connected to Xcode.
6. **Run:** choose the iPhone as the run destination and press Run (⌘R). The first time, Xcode prepares the phone for development, which takes a few minutes.
7. **Trust the developer:** the first launch is refused as an "Untrusted Developer". On the iPhone: Settings → General → VPN & Device Management → your Apple ID → **Trust**. Then press Run again.
8. **Every 7 days,** a free team's profile expires and the app no longer opens. Plug the phone in and press Run again; the app's data is kept.

**Push notifications** need a paid Apple Developer Program team: a free team cannot sign the `aps-environment` entitlement. They are off by default (`PARLEY_PUSH: "NO"` in `ios/project.yml`): the build carries no entitlements and never registers for remote notifications. Without push, Parley still posts a local "Reply ready" notification when a reply becomes ready while it runs in the background, which is shortly after you leave it, or while it plays a reply. With a paid team, add `PARLEY_PUSH: "YES"` to your `ios/project.local.yml` and generate again. The target then signs `ios/Entitlements/Parley-Push.entitlements`: `aps-environment` is `development` for Debug and `production` for Release. The app sends its device token to the relay (`POST /api/v1/devices`, with `environment` set to `sandbox` or `production`).

On the phone, connect Tailscale. In Parley's settings, set the relay (`https://parley.<tailnet>.ts.net`), leave the dev token empty, and tap **Sign in**: Pocket ID opens in a sheet and you sign in with your passkey. The session (a refresh token) stays in the phone's Keychain, and the app renews its access token by itself. The token goes only over https to a relay under `PARLEY_RELAY_HOST_SUFFIX` (`ios/project.yml`; your local spec can change it).

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
