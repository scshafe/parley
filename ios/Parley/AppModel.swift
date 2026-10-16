import AuthenticationServices
import Foundation
import Observation
import ParleyKit
import SwiftUI
import UIKit

typealias ParleyKitTurn = ParleyKit.Turn

/// The app's settings, its sign-in and its relay client. The relay URL lives
/// in UserDefaults, the signed-in session's tokens in the Keychain.
///
/// The app reaches its relay only signed in with Pocket ID: the session's
/// access token, refreshed before it expires, sent only over https to a host
/// under `PARLEY_RELAY_HOST_SUFFIX` (the tailnet). Until then it shows the
/// login screen.
@Observable
@MainActor
final class AppModel {
    /// The UI tests' seam (`UITestSeam`): only a debug build in the simulator
    /// honours it; anywhere else it is always off.
    static let isUITesting = UITestSeam.isActive
    /// The one model, shared with the app delegate (push and notification taps).
    static let shared = AppModel()

    private(set) var relayURLString: String
    private(set) var account: OIDCAccount?
    private(set) var isSignedIn: Bool
    /// True from a sign-in on the login screen until the relay has answered:
    /// the login screen stays up meanwhile, and says so if the relay fails.
    private(set) var awaitingRelayCheck = false
    /// Bumped when the sign-in changes, so an open event stream reconnects.
    /// Not on a refresh: a stream picks the new token up when it reconnects,
    /// and reconnecting on every refresh loops against a relay that refuses.
    private(set) var authGeneration = 0
    /// Bumped each time the app comes back to the foreground: the event stream
    /// reconnects (iOS may have cut it while the app was suspended).
    private(set) var foregroundGeneration = 0

    /// Pocket ID, from the build settings (`PARLEY_OIDC_ISSUER`, `PARLEY_OIDC_CLIENT_ID`).
    let oidcConfiguration: OIDCConfiguration?
    /// Relay hosts that may receive the session token (`PARLEY_RELAY_HOST_SUFFIX`).
    let relayHostSuffix: String
    /// The relay the login screen starts with (`PARLEY_DEFAULT_RELAY_URL`).
    let defaultRelayURL: String
    @ObservationIgnored let session: TokenSession?
    let notifier = Notifier()
    /// A notification the person tapped, for the root view to open.
    private(set) var pendingRoute: NotificationRoute?
    /// Bumped each time the Action Button's intent runs (`NewConversationIntent`):
    /// the root view opens a new conversation and listens, or, while it
    /// listens, sends.
    private(set) var dictatedConversationRequests = 0

    /// Whether the root view shows the login screen instead of the conversations.
    var showsLogin: Bool { !isSignedIn || awaitingRelayCheck }

    init() {
        oidcConfiguration = AppModel.oidcConfigurationFromInfoPlist()
        relayHostSuffix = Bundle.main.object(forInfoDictionaryKey: "ParleyRelayHostSuffix") as? String ?? ""
        defaultRelayURL = (Bundle.main.object(forInfoDictionaryKey: "ParleyDefaultRelayURL") as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let store: TokenStoring
        if let seam = UITestSeam.current {
            // UI tests: a fake session against a local fake relay; nothing is saved.
            relayURLString = seam.relayURL
            store = MemoryTokenStore(seam.startsSignedIn ? seam.tokens : nil)
        } else {
            AppModel.forgetAPreviousInstall()
            AppModel.forgetTheOldDevToken()
            let saved = UserDefaults.standard.string(forKey: "relayURL") ?? ""
            relayURLString = saved.isEmpty ? defaultRelayURL : saved
            store = KeychainTokenStore()
        }
        let saved = store.load()
        account = saved?.account
        isSignedIn = saved != nil
        session = oidcConfiguration.map {
            TokenSession(client: OIDCClient(configuration: $0), store: store, keepAlive: BackgroundRefresh())
        }
        notifier.model = self
        if UITestSeam.current?.opensNewDictatedConversation == true { dictatedConversationRequests = 1 }
        if let session {
            Task { [weak self] in
                await session.setOnChange { change in
                    Task { @MainActor in self?.apply(change) }
                }
            }
        }
    }

    // MARK: The relay

    /// Check a typed relay URL: https, under the build's host suffix (the UI
    /// tests' local relay aside).
    func validate(relayURL raw: String) -> Result<URL, RelayURLProblem> {
        RelayConfiguration.validate(raw, hostSuffix: relayHostSuffix, allowLoopbackHTTP: UITestSeam.isActive)
    }

    /// Save a relay URL that `validate` accepted.
    func update(relayURL url: URL) {
        let new = url.absoluteString
        guard new != relayURLString else { return }
        // Push stops at the old relay, with its own credentials.
        let oldRelay = relayURLString
        let oldClient = client
        Task { await notifier.unregister(from: oldRelay, using: oldClient) }
        relayURLString = new
        if !AppModel.isUITesting {
            UserDefaults.standard.set(new, forKey: "relayURL")
        }
    }

    var relayURL: URL? { try? validate(relayURL: relayURLString).get() }

    var isConfigured: Bool { client != nil }

    /// Why there is no relay client, for the person.
    var configurationProblem: String? {
        if case .failure(let problem) = validate(relayURL: relayURLString) { return problem.localizedDescription }
        guard isSignedIn, session != nil else { return RelayError.signInRequired.localizedDescription }
        return nil
    }

    var client: RelayClient? {
        guard let url = relayURL else { return nil }
        return client(baseURL: url)
    }

    /// A client for `baseURL` (also an unsaved one, for "Check connection"),
    /// with the session's token. `nil` unless signed in and the URL passes
    /// `validate`: the token goes only to an allowed https relay.
    func client(baseURL: URL) -> RelayClient? {
        guard isSignedIn, let session, (try? validate(relayURL: baseURL.absoluteString).get()) != nil else {
            return nil
        }
        return RelayClient(baseURL: baseURL, auth: session)
    }

    /// Changes when the relay or the sign-in changes.
    var connectionKey: String { "\(relayURLString)|\(isSignedIn)|\(authGeneration)" }

    /// Changes when an open event stream should reconnect.
    var streamKey: String { "\(connectionKey)|\(foregroundGeneration)" }

    func cameToForeground() {
        foregroundGeneration += 1
    }

    // MARK: Notifications

    func open(_ route: NotificationRoute) {
        pendingRoute = route
    }

    func clearPendingRoute() {
        pendingRoute = nil
    }

    // MARK: The Action Button

    func requestNewDictatedConversation() {
        dictatedConversationRequests += 1
    }

    // MARK: Signing in

    /// The login screen's button: check the URL, sign in with Pocket ID
    /// (unless already signed in), then check that the relay answers. Throws
    /// `LoginError` for the screen to show; `ASWebAuthenticationSessionError
    /// .canceledLogin` when the person closes the page.
    func logIn(relayURL raw: String, using web: WebAuthenticationSession) async throws {
        let url: URL
        switch validate(relayURL: raw) {
        case .success(let u): url = u
        case .failure(let problem): throw LoginError.relayURL(problem)
        }
        awaitingRelayCheck = true
        update(relayURL: url)
        if !isSignedIn {
            do {
                try await signIn(using: web)
            } catch {
                awaitingRelayCheck = false
                throw error
            }
        }
        guard let client = client(baseURL: url) else {
            throw LoginError.relayUnreachable(RelayError.notConfigured.localizedDescription)
        }
        do {
            _ = try await client.listConversations()
        } catch RelayError.signInRequired {
            awaitingRelayCheck = false
            throw LoginError.signIn(RelayError.signInRequired.localizedDescription)
        } catch {
            throw LoginError.relayUnreachable((error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
        awaitingRelayCheck = false
    }

    /// Pocket ID's sign-in page in a web authentication session, then the code
    /// exchange. Throws `ASWebAuthenticationSessionError.canceledLogin` when the
    /// person closes the page.
    private func signIn(using web: WebAuthenticationSession) async throws {
        guard let session, let config = oidcConfiguration else {
            throw OIDCError.discovery("this build has no Pocket ID issuer")
        }
        if let seam = UITestSeam.current {
            // UI tests: no Pocket ID; the fake session signs in at once.
            await session.signedIn(with: seam.tokens)
            apply(.signedIn(seam.tokens.account))
            return
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

    /// Sign out: first stop push at the relay (that needs the token), then
    /// forget the tokens. The root view goes back to the login screen.
    func signOut() async {
        if isSignedIn { await notifier.unregister(from: relayURLString, using: client) }
        awaitingRelayCheck = false
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
            return
        case .signedOut:
            if !isSignedIn { return }
            account = nil
            isSignedIn = false
        }
        authGeneration += 1
    }

    /// The Keychain outlives a deleted app; UserDefaults does not. On the
    /// first launch of a new install, drop what an old one left there.
    private static func forgetAPreviousInstall() {
        let key = "installed"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        Keychain.removeAll()
        UserDefaults.standard.set(true, forKey: key)
    }

    /// Builds before the login screen had a dev token in the Keychain
    /// (`relayToken`). Delete it once.
    private static func forgetTheOldDevToken() {
        let key = "devTokenRemoved"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        if Keychain.set(data: nil, for: "relayToken") { UserDefaults.standard.set(true, forKey: key) }
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

/// What the login screen says when it cannot go on.
enum LoginError: Error, LocalizedError {
    case relayURL(RelayURLProblem)
    case signIn(String)
    case relayUnreachable(String)

    var errorDescription: String? {
        switch self {
        case .relayURL(let problem): return problem.localizedDescription
        case .signIn(let why): return why
        case .relayUnreachable(let why): return "You are signed in, but the relay did not answer. \(why)"
        }
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

/// A background task around a token refresh, so the rotated refresh token is
/// saved even if the app is leaving the foreground.
struct BackgroundRefresh: RefreshKeepAlive {
    @MainActor func begin() async -> Int {
        let box = TaskBox()
        box.id = UIApplication.shared.beginBackgroundTask(withName: "parley.token-refresh") {
            // Out of time: end it rather than be killed; the refresh is retried later.
            MainActor.assumeIsolated {
                if box.id != .invalid { UIApplication.shared.endBackgroundTask(box.id) }
                box.id = .invalid
            }
        }
        return box.id.rawValue
    }

    @MainActor func end(_ id: Int) async {
        let task = UIBackgroundTaskIdentifier(rawValue: id)
        if task != .invalid { UIApplication.shared.endBackgroundTask(task) }
    }
}

private final class TaskBox: @unchecked Sendable {
    var id: UIBackgroundTaskIdentifier = .invalid
}
