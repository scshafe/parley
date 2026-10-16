import Foundation

/// Where a signed-in session's tokens are kept between launches (the app's
/// Keychain; memory in tests).
public protocol TokenStoring: Sendable {
    func load() -> OIDCTokens?
    func save(_ tokens: OIDCTokens?)
}

/// A store that forgets on exit: tests and UI tests.
public final class MemoryTokenStore: TokenStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: OIDCTokens?

    public init(_ tokens: OIDCTokens? = nil) {
        self.tokens = tokens
    }

    public func load() -> OIDCTokens? { lock.withLock { tokens } }
    public func save(_ tokens: OIDCTokens?) { lock.withLock { self.tokens = tokens } }
}

/// Keeps the app alive while a refresh is in flight (the app's
/// `beginBackgroundTask`), so a refresh that Pocket ID has already rotated is
/// not cut off before the new refresh token is saved.
public protocol RefreshKeepAlive: Sendable {
    func begin() async -> Int
    func end(_ id: Int) async
}

/// The signed-in session, as the relay client's bearer: it hands out the
/// access token, refreshes it a minute before it expires (one refresh at a
/// time, however many calls wait on it), and refreshes early when the relay
/// refuses the current one, but not twice within `rejectionRefreshInterval`:
/// a relay that keeps refusing fresh tokens (the wrong relay, a misconfigured
/// door) then gets `.unauthorized` instead of a refresh loop. A refused
/// refresh token ends the session.
public actor TokenSession: BearerProvider {
    public enum Change: Equatable, Sendable {
        case signedIn(OIDCAccount?)
        case refreshed
        case signedOut
    }

    /// Refresh this long before the access token expires.
    public static let leeway: TimeInterval = 60
    /// At most one refresh per this interval because the relay refused a token.
    public static let rejectionRefreshInterval: TimeInterval = 30

    private let client: OIDCClient
    private let store: TokenStoring
    private let now: @Sendable () -> Date
    private var tokens: OIDCTokens?
    private var refreshing: Task<OIDCTokens, Error>?
    /// Bumped by every sign-in and sign-out, so a refresh that started before
    /// one cannot write over it.
    private var generation = 0
    private var onChange: (@Sendable (Change) -> Void)?
    private var lastRejectionRefresh: Date?
    private let keepAlive: RefreshKeepAlive?

    public init(client: OIDCClient, store: TokenStoring, keepAlive: RefreshKeepAlive? = nil,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.client = client
        self.store = store
        self.keepAlive = keepAlive
        self.now = now
        tokens = store.load()
    }

    public nonisolated var oidc: OIDCClient { client }

    public func setOnChange(_ handler: (@Sendable (Change) -> Void)?) {
        onChange = handler
    }

    public var current: OIDCTokens? { tokens }
    public var isSignedIn: Bool { tokens != nil }

    public func signedIn(with fresh: OIDCTokens) {
        generation += 1
        lastRejectionRefresh = nil
        refreshing?.cancel()
        refreshing = nil
        tokens = fresh
        store.save(fresh)
        onChange?(.signedIn(fresh.account))
    }

    /// Forget the tokens, and revoke the refresh token at the issuer if it
    /// offers revocation (best effort, after the tokens are gone here).
    public func signOut() async {
        let refreshToken = tokens?.refreshToken
        generation += 1
        refreshing?.cancel()
        refreshing = nil
        tokens = nil
        store.save(nil)
        onChange?(.signedOut)
        if let refreshToken { await client.revoke(refreshToken: refreshToken) }
    }

    // MARK: BearerProvider

    public func currentToken() async throws -> String {
        guard let t = tokens else { throw RelayError.signInRequired }
        if t.expiresAt.timeIntervalSince(now()) > Self.leeway { return t.accessToken }
        return try await refresh().accessToken
    }

    public func tokenAfterRejection(_ rejected: String) async throws -> String? {
        guard let t = tokens else { throw RelayError.signInRequired }
        // Another call already refreshed: try the newer token.
        if t.accessToken != rejected { return t.accessToken }
        if let last = lastRejectionRefresh, now().timeIntervalSince(last) < Self.rejectionRefreshInterval {
            return nil
        }
        lastRejectionRefresh = now()
        return try await refresh().accessToken
    }

    // MARK: Refreshing

    /// Refresh now, or join the refresh already running. A refresh that
    /// finishes after a sign-out (or a new sign-in) is dropped, and its
    /// callers get `.signInRequired`.
    public func refresh() async throws -> OIDCTokens {
        let joined = generation
        if let refreshing {
            let fresh = try await Self.mapped { try await refreshing.value }
            guard generation == joined else { throw RelayError.signInRequired }
            return fresh
        }
        guard let t = tokens else { throw RelayError.signInRequired }
        let client = self.client
        let keepAlive = self.keepAlive
        let started = generation
        // The task saves the new tokens itself, inside the keep-alive, so a
        // rotated refresh token is stored before the app may be suspended.
        let task = Task { () throws -> OIDCTokens in
            let id = await keepAlive?.begin()
            do {
                let fresh = try await client.refresh(t)
                try self.adopt(fresh, started: started)
                if let id { await keepAlive?.end(id) }
                return fresh
            } catch {
                self.refreshFailed(error, started: started)
                if let id { await keepAlive?.end(id) }
                throw error
            }
        }
        refreshing = task
        defer { if refreshing == task { refreshing = nil } }
        return try await Self.mapped { try await task.value }
    }

    private func adopt(_ fresh: OIDCTokens, started: Int) throws {
        guard generation == started else { throw RelayError.signInRequired }
        tokens = fresh
        store.save(fresh)
        onChange?(.refreshed)
    }

    private func refreshFailed(_ error: Error, started: Int) {
        guard case OIDCError.signInRequired = error, generation == started else { return }
        generation += 1
        tokens = nil
        store.save(nil)
        onChange?(.signedOut)
    }

    private static func mapped<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch {
            throw relayError(error)
        }
    }

    private static func relayError(_ error: Error) -> Error {
        switch error {
        case let e as RelayError: return e
        case OIDCError.signInRequired: return RelayError.signInRequired
        case OIDCError.transport(let what): return RelayError.transport("sign-in service: \(what)")
        case is CancellationError: return error
        default: return RelayError.transport((error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
    }
}
