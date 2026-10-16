import Foundation
import ParleyKit

/// How the UI tests drive the app without Pocket ID: a fake signed-in
/// session against a local fake relay (`parley-relay --dev`, plain http on
/// this machine). Compiled only into a debug build for the simulator, and
/// active only when the test runner sets `PARLEY_UI_TESTING=1`; a release
/// build, or any build on a phone, has none of it.
///
/// - `PARLEY_UI_TEST_RELAY_URL`: the relay the app starts with
///   (default `http://127.0.0.1:8765`).
/// - `PARLEY_UI_TEST_ACCESS_TOKEN`: the fake session's access token (the dev
///   relay's bearer).
/// - `PARLEY_UI_TEST_SIGNED_IN=1`: start signed in; otherwise the app starts
///   on the login screen, and its Sign in button signs the fake session in
///   without opening Pocket ID.
///
/// With the seam on, the relay URL may also be plain http to this machine,
/// nothing is saved (the session lives in memory) and the cache is in memory.
struct UITestSeam {
    let relayURL: String
    let tokens: OIDCTokens
    let startsSignedIn: Bool

    static let current: UITestSeam? = {
        #if DEBUG && targetEnvironment(simulator)
        let env = ProcessInfo.processInfo.environment
        guard env["PARLEY_UI_TESTING"] == "1" else { return nil }
        let token = env["PARLEY_UI_TEST_ACCESS_TOKEN"] ?? ""
        let account = OIDCAccount(subject: "ui-test", name: "UI test")
        return UITestSeam(
            relayURL: env["PARLEY_UI_TEST_RELAY_URL"] ?? "http://127.0.0.1:8765",
            tokens: OIDCTokens(accessToken: token, refreshToken: nil, idToken: nil, expiresAt: .distantFuture,
                               account: account),
            startsSignedIn: env["PARLEY_UI_TEST_SIGNED_IN"] == "1")
        #else
        return nil
        #endif
    }()

    static var isActive: Bool { current != nil }
}
