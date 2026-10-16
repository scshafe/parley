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

/// The signed-in session, as the relay client's bearer: it hands out the
/// access token, refreshes it a minute before it expires (one refresh at a
/// time, however many calls wait on it), and refreshes early when the relay
/// refuses the current one. A refused refresh token ends the session.
public actor TokenSession: BearerProvider {
    public enum Change: Equatable, Sendable {
        case signedIn(OIDCAccount?)
        case refreshed
        case signedOut
    }

    /// Refresh this long before the access token expires.
    public static let leeway: TimeInterval = 60

    private let client: OIDCClient
    private let store: TokenStoring
    private let now: @Sendable () -> Date
    private var tokens: OIDCTokens?
    private var refreshing: Task<OIDCTokens, Error>?
    /// Bumped by every sign-in and sign-out, so a refresh that started before
    /// one cannot write over it.
    private var generation = 0
    private var onChange: (@Sendable (Change) -> Void)?

    public init(client: OIDCClient, store: TokenStoring, now: @escaping @Sendable () -> Date = { Date() }) {
        self.client = client
        self.store = store
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
        refreshing?.cancel()
        refreshing = nil
        tokens = fresh
        store.save(fresh)
        onChange?(.signedIn(fresh.account))
    }

    public func signOut() {
        generation += 1
        refreshing?.cancel()
        refreshing = nil
        tokens = nil
        store.save(nil)
        onChange?(.signedOut)
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
        return try await refresh().accessToken
    }

    // MARK: Refreshing

    /// Refresh now, or join the refresh already running.
    public func refresh() async throws -> OIDCTokens {
        if let refreshing { return try await Self.mapped { try await refreshing.value } }
        guard let t = tokens else { throw RelayError.signInRequired }
        let client = self.client
        let task = Task { try await client.refresh(t) }
        let started = generation
        refreshing = task
        defer { if refreshing == task { refreshing = nil } }
        do {
            let fresh = try await task.value
            guard generation == started else { throw RelayError.signInRequired }
            tokens = fresh
            store.save(fresh)
            onChange?(.refreshed)
            return fresh
        } catch OIDCError.signInRequired {
            if generation == started {
                generation += 1
                tokens = nil
                store.save(nil)
                onChange?(.signedOut)
            }
            throw RelayError.signInRequired
        } catch {
            throw Self.relayError(error)
        }
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
