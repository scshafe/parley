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
uv run parley-relay --dev          # http://127.0.0.1:8765, token parley-dev, loopback only
```

The app is built on a Mac with Xcode 26:

```sh
brew install xcodegen              # CI pins 2.46.0
xcodegen generate --spec ios/project.yml
open ios/Parley.xcodeproj          # run on an iPhone simulator
```

The app opens on its login screen: the relay's address (prefilled with the build's `PARLEY_DEFAULT_RELAY_URL`) and **Sign in**, which signs in with Pocket ID. It talks only to a relay it is signed in to, over https under `PARLEY_RELAY_HOST_SUFFIX`, so it never takes a dev relay's token.

To try a simulator build against the dev relay, use the UI tests' seam (`ios/Parley/UITestSeam.swift`): in the scheme's *Run* action, set the environment variables `PARLEY_UI_TESTING=1` and `PARLEY_UI_TEST_ACCESS_TOKEN=parley-dev`. A debug build in the simulator then accepts `http://127.0.0.1:8765`, and **Sign in** signs a fake session in without Pocket ID. Nothing is saved. A release build, or any build on a phone, ignores these variables.

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

**Push notifications** need a paid Apple Developer Program team: a free team cannot sign the `aps-environment` entitlement. They are off by default (`PARLEY_PUSH: "NO"` in `ios/project.yml`): the build carries no entitlements and never registers for remote notifications. Without push, Parley still posts a local "Reply ready" notification when a reply becomes ready while it runs in the background, which is shortly after you leave it, or while it plays a reply. With a paid team, add `PARLEY_PUSH: "YES"` to your `ios/project.local.yml` and generate again. The target then signs `ios/Entitlements/Parley-Push.entitlements`, with `aps-environment` `development`; an export for the App Store or TestFlight rewrites it. The app reads its APNs environment from its provisioning profile and registers its device token with the relay (`POST /api/v1/devices`). It removes that registration when you sign out or change the relay.

On the phone, connect Tailscale and open Parley. The login screen shows the relay's address, `https://parley.<tailnet>.ts.net` by default (`PARLEY_DEFAULT_RELAY_URL`; change it there if yours differs). Tap **Sign in**: Pocket ID opens in a sheet and you sign in with your passkey. The app then checks that the relay answers and opens your conversations; if the address is wrong or the relay does not answer, the login screen says so under the address. The session (a refresh token) stays in the phone's Keychain, and the app renews its access token by itself. The token goes only over https to a relay under `PARLEY_RELAY_HOST_SUFFIX` (`ios/project.yml`; your local spec can change it). **Sign out** is in Settings (the gear), and returns to the login screen.

## Talk instead of typing: the Action Button

Parley has one App Shortcut, **New Parley Conversation**. It opens Parley on a new conversation that is already listening: say your first message, and Parley sends it once you pause for about two seconds. The reply comes back as usual.

**Assign it to the Action Button** (iPhone 15 Pro and later): Settings → Action Button → swipe to **Shortcut** → **Choose a Shortcut** → **Parley** → **New Parley Conversation**. It is also in the Shortcuts app, and Siri knows "New Parley conversation" and "Talk to Parley".

Using it:

1. Press the Action Button. Parley opens on a new conversation. A playing reply stops. The bar above the composer says **Listening…**, and your words appear in the message field as you speak.
2. Stop talking: about two seconds after the last word, the message is sent. Or send it at once by tapping **Send**, or by pressing the Action Button again.
3. **Cancel** in the listening bar throws the words away. Nothing heard for 20 seconds stops listening, and nothing is sent.
4. If you are not signed in, Parley opens on its login screen instead.

The **mic** button next to the message field dictates in any conversation. It puts the words in the field without sending them by itself: tap the mic again to stop, or **Send**. Leaving Parley while it listens stops listening and keeps the words in the field.

**The first time** you dictate, iOS asks two questions. Allow both:

- *"Parley" Would Like to Access the Microphone*: "Parley listens while you dictate a message, so you can talk to your agent instead of typing."
- *"Parley" Would Like to Access Speech Recognition*: "Parley turns what you say into the text of your message. Speech is recognized on this iPhone where it can be."

If you said no, Parley says which one is off. Turn it back on in Settings → Apps → Parley. The first dictation in a language can also download Apple's speech model, which shows "Getting speech recognition ready…".

Speech is recognized on the phone with iOS 26's SpeechAnalyzer: `SpeechTranscriber` where the iPhone supports it, otherwise `DictationTranscriber`. If neither can start (the simulator, for one), Parley falls back to `SFSpeechRecognizer`. That is on device where the iPhone supports it for the language, and otherwise Apple's speech servers.

## Build and test

```sh
./scripts/verify-linux
```

This is the repository's one verify command (`dev.toml [verify]`). It runs shell syntax checks, the repository's own tests, and the relay's tests (uv, no network).

CI (`.github/workflows/ci.yml`) runs it on Linux. On `macos-26` it also builds and tests the iOS app:

1. `swift test` runs ParleyKit's tests.
2. XcodeGen generates the project.
3. `parley-relay --dev` starts on the runner.
4. `xcodebuild test` runs the UI tests on an iPhone simulator against that relay. They sign in through the app's debug-only UI-test seam (a fake session; no Pocket ID) and cover the login screen's errors, sending a turn, the reader-player, and dictation: the Action Button's listening conversation that sends after the pause, and the composer's mic. A scripted "speech" stands in for the microphone.

The test results, with screenshots, are kept as the run's `ios-test-results` artifact.
