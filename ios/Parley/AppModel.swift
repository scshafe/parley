import Foundation
import Observation
import ParleyKit

typealias ParleyKitTurn = ParleyKit.Turn

/// The app's settings and its relay client. The relay URL lives in
/// UserDefaults, the token in the Keychain.
@Observable
@MainActor
final class AppModel {
    static let isUITesting = ProcessInfo.processInfo.environment["PARLEY_UI_TESTING"] == "1"

    private(set) var relayURLString: String
    private(set) var token: String

    init() {
        let env = ProcessInfo.processInfo.environment
        if AppModel.isUITesting {
            // UI tests point the app at a dev relay (`parley-relay --dev`).
            relayURLString = env["PARLEY_RELAY_URL"] ?? "http://127.0.0.1:8765"
            token = env["PARLEY_DEV_TOKEN"] ?? "parley-dev"
        } else {
            relayURLString = UserDefaults.standard.string(forKey: "relayURL") ?? ""
            token = Keychain.get("relayToken") ?? ""
        }
    }

    /// Save new settings: the URL to UserDefaults, the token to the Keychain.
    func update(relayURL: String, token: String) {
        relayURLString = relayURL
        self.token = token
        UserDefaults.standard.set(relayURL, forKey: "relayURL")
        Keychain.set(token, for: "relayToken")
    }

    var relayURL: URL? { RelayConfiguration.parseURL(relayURLString) }

    var isConfigured: Bool { relayURL != nil && !token.isEmpty }

    var client: RelayClient? {
        guard let url = relayURL, !token.isEmpty else { return nil }
        return RelayClient(configuration: RelayConfiguration(baseURL: url, token: token))
    }
}
