import AuthenticationServices
import Foundation
import Observation
import ParleyKit
import SwiftUI

typealias ParleyKitTurn = ParleyKit.Turn

/// The app's settings, its sign-in and its relay client. The relay URL lives
/// in UserDefaults; the dev token and the signed-in session's tokens in the
/// Keychain.
///
/// Two ways to authenticate to the relay:
/// - **Sign in** with Pocket ID (a real relay behind the door): the session's
///   access token, refreshed before it expires.
/// - **A dev token** (a dev relay, `parley-relay --dev`): sent as it is. When
///   one is set it is used instead of the sign-in.
@Observable
@MainActor
final class AppModel {
    static let isUITesting = ProcessInfo.processInfo.environment["PARLEY_UI_TESTING"] == "1"

    enum AuthMode: Equatable {
        case devToken
        case signedIn
        case none
    }

    private(set) var relayURLString: String
    private(set) var devToken: String
    private(set) var account: OIDCAccount?
    private(set) var isSignedIn: Bool
    /// Bumped when the sign-in changes or its access token is refreshed, so an
    /// open event stream reconnects with the new token.
    private(set) var authGeneration = 0
    /// Bumped each time the app comes back to the foreground: the event stream
    /// reconnects (iOS may have cut it while the app was suspended).
    private(set) var foregroundGeneration = 0

    /// Pocket ID, from the build settings (`PARLEY_OIDC_ISSUER`, `PARLEY_OIDC_CLIENT_ID`).
    let oidcConfiguration: OIDCConfiguration?
    @ObservationIgnored let session: TokenSession?

    init() {
        let env = ProcessInfo.processInfo.environment
        oidcConfiguration = AppModel.oidcConfigurationFromInfoPlist()
        let store: TokenStoring
        if AppModel.isUITesting {
            // UI tests point the app at a dev relay (`parley-relay --dev`).
            relayURLString = env["PARLEY_RELAY_URL"] ?? "http://127.0.0.1:8765"
            devToken = env["PARLEY_DEV_TOKEN"] ?? "parley-dev"
            store = MemoryTokenStore()
        } else {
            relayURLString = UserDefaults.standard.string(forKey: "relayURL") ?? ""
            devToken = Keychain.get("relayToken") ?? ""
            store = KeychainTokenStore()
        }
        let saved = store.load()
        account = saved?.account
        isSignedIn = saved != nil
        session = oidcConfiguration.map { TokenSession(client: OIDCClient(configuration: $0), store: store) }
        if let session {
            Task { [weak self] in
                await session.setOnChange { change in
                    Task { @MainActor in self?.apply(change) }
                }
            }
        }
    }

    // MARK: Settings

    /// Save new settings: the URL to UserDefaults, the dev token to the Keychain.
    func update(relayURL: String, devToken: String) {
        relayURLString = relayURL
        self.devToken = devToken
        if !AppModel.isUITesting {
            UserDefaults.standard.set(relayURL, forKey: "relayURL")
            Keychain.set(devToken, for: "relayToken")
        }
    }

    var relayURL: URL? { RelayConfiguration.parseURL(relayURLString) }

    var authMode: AuthMode {
        if !devToken.isEmpty { return .devToken }
        return isSignedIn ? .signedIn : .none
    }

    var isConfigured: Bool { relayURL != nil && authMode != .none }

    var client: RelayClient? {
        guard let url = relayURL else { return nil }
        return client(baseURL: url, devToken: devToken)
    }

    /// A client for settings that are not saved yet ("Check connection").
    func client(baseURL: URL, devToken: String) -> RelayClient? {
        if !devToken.isEmpty { return RelayClient(baseURL: baseURL, auth: StaticBearer(token: devToken)) }
        guard isSignedIn, let session else { return nil }
        return RelayClient(baseURL: baseURL, auth: session)
    }

    /// Changes when the relay or the way to authenticate to it changes.
    var connectionKey: String { "\(relayURLString)|\(authMode)|\(devToken.hashValue)" }

    /// Changes when an open event stream should reconnect.
    var streamKey: String { "\(connectionKey)|\(authGeneration)|\(foregroundGeneration)" }

    func cameToForeground() {
        foregroundGeneration += 1
    }

    // MARK: Signing in

    /// Pocket ID's sign-in page in a web authentication session, then the code
    /// exchange. Throws `ASWebAuthenticationSessionError.canceledLogin` when the
    /// person closes the page.
    func signIn(using web: WebAuthenticationSession) async throws {
        guard let session, let config = oidcConfiguration else {
            throw OIDCError.discovery("this build has no Pocket ID issuer")
        }
        let oidc = session.oidc
        let discovery = try await oidc.discover()
        let request = oidc.authorizationRequest(discovery)
        let callback = try await web.authenticate(using: request.url, callback: .customScheme(config.callbackScheme),
                                                  preferredBrowserSession: .ephemeral, additionalHeaderFields: [:])
        let code = try oidc.authorizationCode(from: callback, for: request)
        let tokens = try await oidc.exchange(code: code, for: request)
        await session.signedIn(with: tokens)
        apply(.signedIn(tokens.account))
    }

    func signOut() async {
        await session?.signOut()
        apply(.signedOut)
    }

    private func apply(_ change: TokenSession.Change) {
        switch change {
        case .signedIn(let who):
            if isSignedIn && account == who { return }
            account = who
            isSignedIn = true
        case .refreshed:
            break
        case .signedOut:
            if !isSignedIn { return }
            account = nil
            isSignedIn = false
        }
        authGeneration += 1
    }

    private static func oidcConfigurationFromInfoPlist() -> OIDCConfiguration? {
        let info = Bundle.main.infoDictionary ?? [:]
        guard let issuer = (info["ParleyOIDCIssuer"] as? String).flatMap({ URL(string: $0) }), issuer.host != nil,
              let clientID = info["ParleyOIDCClientID"] as? String, !clientID.isEmpty,
              let redirect = (info["ParleyOIDCRedirectURI"] as? String).flatMap({ URL(string: $0) }) else {
            return nil
        }
        return OIDCConfiguration(issuer: issuer, clientID: clientID, redirectURI: redirect)
    }
}

/// The signed-in session's tokens as one Keychain item (this device only,
/// readable after first unlock so a refresh works in the background).
struct KeychainTokenStore: TokenStoring {
    private static let account = "oidcTokens"

    func load() -> OIDCTokens? {
        guard let data = Keychain.data(Self.account) else { return nil }
        return try? JSONDecoder().decode(OIDCTokens.self, from: data)
    }

    func save(_ tokens: OIDCTokens?) {
        Keychain.set(data: tokens.flatMap { try? JSONEncoder().encode($0) }, for: Self.account)
    }
}
