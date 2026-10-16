import Foundation

/// The relay's address, as the person types it, and where the signed-in
/// session's token may go.
public enum RelayConfiguration {
    /// Parse a typed relay URL: `https://relay.example.ts.net`, or `http://`
    /// (refused later for the session token). A bare host gets `https://`.
    public static func parseURL(_ raw: String) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "https://" + text }
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http", let host = url.host, !host.isEmpty else {
            return nil
        }
        return url
    }

    /// Whether a signed-in session's token may be sent to `url`: only over
    /// https, and only to a host under `hostSuffix` (for example
    /// `.example.ts.net`, the tailnet). An empty suffix allows no host.
    public static func allowsSessionToken(to url: URL, hostSuffix: String) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased(), !host.isEmpty else { return false }
        let suffix = hostSuffix.trimmingCharacters(in: .whitespaces).lowercased()
        guard !suffix.isEmpty else { return false }
        let dotted = suffix.hasPrefix(".") ? suffix : "." + suffix
        return host.hasSuffix(dotted) && host.count > dotted.count
    }

    /// Whether `url` is plain http to this machine (`127.0.0.1`, `::1`,
    /// `localhost`): only the app's UI tests, in a debug simulator build,
    /// accept one (a local fake relay).
    public static func isLoopbackHTTP(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "http", let host = url.host?.lowercased() else { return false }
        return host == "127.0.0.1" || host == "::1" || host == "[::1]" || host == "localhost"
    }

    /// The relay URL from the login screen or Settings, checked before the
    /// session's token may go to it: it must parse, be https, and be a host
    /// under `hostSuffix`. `allowLoopbackHTTP` (UI tests only) also accepts
    /// plain http to this machine.
    public static func validate(_ raw: String, hostSuffix: String,
                                allowLoopbackHTTP: Bool = false) -> Result<URL, RelayURLProblem> {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.empty) }
        guard let url = parseURL(trimmed) else { return .failure(.invalid) }
        if allowLoopbackHTTP && isLoopbackHTTP(url) { return .success(url) }
        let suffix = hostSuffix.trimmingCharacters(in: .whitespaces)
        guard !suffix.isEmpty else { return .failure(.noHostSuffixInBuild) }
        guard url.scheme?.lowercased() == "https" else { return .failure(.notHTTPS) }
        guard allowsSessionToken(to: url, hostSuffix: suffix) else { return .failure(.outsideHostSuffix(suffix)) }
        return .success(url)
    }
}

/// Why a relay URL cannot be used with the sign-in, for the person.
public enum RelayURLProblem: Error, Equatable, LocalizedError {
    case empty
    case invalid
    case notHTTPS
    case outsideHostSuffix(String)
    case noHostSuffixInBuild

    public var errorDescription: String? {
        switch self {
        case .empty: return "Enter your relay's address."
        case .invalid: return "That is not a relay address. It looks like https://parley.example.ts.net."
        case .notHTTPS: return "The relay's address must start with https://. Your sign-in is never sent over plain http."
        case .outsideHostSuffix(let suffix):
            let shown = suffix.hasPrefix(".") ? "*" + suffix : "*." + suffix
            return "Your sign-in is sent only to a relay under \(shown). Check the address."
        case .noHostSuffixInBuild: return "This build allows no relay host (PARLEY_RELAY_HOST_SUFFIX is empty)."
        }
    }
}

public enum RelayError: Error, Equatable, LocalizedError {
    case notConfigured
    case unauthorized
    case signInRequired
    case http(status: Int, code: String, detail: String)
    case badResponse
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured: return "Set the relay's address and sign in."
        case .unauthorized: return "The relay refused your sign-in. Sign out and sign in again, or check the relay's address."
        case .signInRequired: return "Your sign-in has ended. Sign in again."
        case .http(let status, let code, let detail): return "The relay answered \(status) \(code): \(detail)"
        case .badResponse: return "The relay's answer could not be read."
        case .transport(let what): return "The relay could not be reached (\(what))."
        }
    }
}

/// Where the relay client gets its bearer token: the signed-in session,
/// which refreshes its access token (`TokenSession`).
public protocol BearerProvider: Sendable {
    /// The token to send now. A session refreshes one that is about to expire.
    func currentToken() async throws -> String
    /// After the relay refused `rejected` (401): a different token to retry
    /// with once, or `nil` when there is none. Throws `RelayError.signInRequired`
    /// when the session has ended.
    func tokenAfterRejection(_ rejected: String) async throws -> String?
}

/// Relay calls follow a redirect only within the same origin (scheme, host
/// and port), so the bearer token never goes to another host.
public final class SameOriginRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(Self.allows(from: task.originalRequest?.url, to: request.url) ? request : nil)
    }

    static func allows(from: URL?, to: URL?) -> Bool {
        guard let from, let to else { return false }
        return from.scheme?.lowercased() == to.scheme?.lowercased() && from.host?.lowercased() == to.host?.lowercased()
            && from.port == to.port
    }
}

/// The relay's API, for the app. Every call carries the current bearer token;
/// a call the relay refuses with 401 is retried once with a fresh token.
public final class RelayClient: @unchecked Sendable {
    public let baseURL: URL
    public let auth: BearerProvider
    private let session: URLSession
    private let redirects = SameOriginRedirects()

    public init(baseURL: URL, auth: BearerProvider, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.auth = auth
        self.session = session
    }

    public func url(_ path: String) -> URL {
        // Paths from the relay are absolute ("/api/v1/..."); keep any base path.
        var base = baseURL.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        return URL(string: base + (path.hasPrefix("/") ? path : "/" + path))!
    }

    func request(_ path: String, method: String = "GET", body: Data? = nil, token: String) -> URLRequest {
        var req = URLRequest(url: url(path))
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        req.timeoutInterval = 30
        return req
    }

    /// Runs `operation` with the current token and, if the relay refuses it
    /// (401), once more with the token the provider offers instead.
    func authorized<T>(_ operation: (String) async throws -> T) async throws -> T {
        let token = try await currentToken()
        do {
            return try await operation(token)
        } catch RelayError.unauthorized {
            guard let fresh = try await auth.tokenAfterRejection(token), fresh != token else {
                throw RelayError.unauthorized
            }
            return try await operation(fresh)
        }
    }

    private func currentToken() async throws -> String {
        do {
            return try await auth.currentToken()
        } catch let error as RelayError {
            throw error
        } catch {
            throw RelayError.transport((error as NSError).localizedDescription)
        }
    }

    /// The response body of a successful call; 401 is `RelayError.unauthorized`.
    func data(_ path: String, method: String = "GET", body: Data? = nil) async throws -> Data {
        try await authorized { token in
            let req = request(path, method: method, body: body, token: token)
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: req, delegate: redirects)
            } catch {
                throw RelayError.transport((error as NSError).localizedDescription)
            }
            try Self.check(response, data)
            return data
        }
    }

    func send<T: Decodable>(_ path: String, method: String = "GET", body: Data? = nil, as type: T.Type) async throws -> T {
        let data = try await data(path, method: method, body: body)
        do {
            return try ParleyJSON.decoder.decode(T.self, from: data)
        } catch {
            throw RelayError.badResponse
        }
    }

    static func check(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw RelayError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 { throw RelayError.unauthorized }
            let info = (try? ParleyJSON.decoder.decode(ErrorEnvelope.self, from: data))?.error
            throw RelayError.http(status: http.statusCode, code: info?.code ?? "http_\(http.statusCode)",
                                  detail: info?.detail ?? "")
        }
    }

    // MARK: Conversations

    public func listConversations() async throws -> [Conversation] {
        try await send("/api/v1/conversations", as: ConversationList.self).conversations
    }

    public func createConversation(title: String? = nil) async throws -> Conversation {
        let body = try JSONSerialization.data(withJSONObject: title.map { ["title": $0] } ?? [String: String]())
        return try await send("/api/v1/conversations", method: "POST", body: body, as: Conversation.self)
    }

    public func conversation(id: String) async throws -> Conversation {
        try await send("/api/v1/conversations/\(id)", as: Conversation.self)
    }

    // MARK: Turns

    /// Send a turn. A retry with the same `clientTurnID` is safe: the relay
    /// answers the turn it already has.
    public func sendTurn(conversationID: String, text: String, clientTurnID: String) async throws -> Turn {
        let body = try JSONSerialization.data(withJSONObject: ["text": text, "client_turn_id": clientTurnID])
        return try await send("/api/v1/conversations/\(conversationID)/turns", method: "POST", body: body,
                              as: Turn.self)
    }

    public func turn(conversationID: String, turnID: String) async throws -> Turn {
        try await send("/api/v1/conversations/\(conversationID)/turns/\(turnID)", as: Turn.self)
    }

    public func timingsData(for turn: Turn) async throws -> Data {
        guard let path = turn.timingsUrl else { throw RelayError.badResponse }
        return try await data(path)
    }

    public func timings(for turn: Turn) async throws -> Timings {
        let data = try await timingsData(for: turn)
        do {
            return try Timings.decode(data, for: turn.replyText ?? "")
        } catch {
            throw RelayError.badResponse
        }
    }

    /// Download a ready turn's audio to `destination` (replacing a file there).
    public func downloadAudio(for turn: Turn, to destination: URL) async throws {
        guard let path = turn.audio?.url else { throw RelayError.badResponse }
        let tmp: URL = try await authorized { token in
            let (tmp, response): (URL, URLResponse)
            do {
                (tmp, response) = try await session.download(for: request(path, token: token), delegate: redirects)
            } catch {
                throw RelayError.transport((error as NSError).localizedDescription)
            }
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                let data = (try? Data(contentsOf: tmp)) ?? Data()
                try? FileManager.default.removeItem(at: tmp)
                try Self.check(response, data)
            }
            return tmp
        }
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.moveItem(at: tmp, to: destination)
    }

    // MARK: Devices

    /// Register this phone's APNs device token for "reply ready" pushes.
    /// `environment` is the APNs environment the token belongs to: `sandbox`
    /// (a development-signed build) or `production`. Registering the same
    /// token again answers the same device.
    public func registerDevice(token: String, environment: String) async throws -> DeviceRegistration {
        let body = try JSONSerialization.data(withJSONObject: ["token": token, "environment": environment])
        return try await send("/api/v1/devices", method: "POST", body: body, as: DeviceRegistration.self)
    }

    /// Stop pushes to a registered device. An id the relay no longer knows
    /// (404) counts as done.
    public func unregisterDevice(id: String) async throws {
        do {
            _ = try await data("/api/v1/devices/\(id)", method: "DELETE")
        } catch RelayError.http(status: 404, _, _) {
            return
        }
    }

    // MARK: Events

    /// The conversation's `turn.updated` events after `after`, as they happen.
    /// The stream ends when the relay closes it (every 10 minutes) or on error;
    /// the caller reconnects with the last event id, and so with the token
    /// that is current then. Opening it is retried once after a 401.
    public func events(conversationID: String, after: Int) -> AsyncThrowingStream<RelayEvent, Error> {
        let path = "/api/v1/conversations/\(conversationID)/events?after=\(after)"
        let session = self.session
        let redirects = self.redirects
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let bytes: URLSession.AsyncBytes = try await self.authorized { token in
                        var req = self.request(path, token: token)
                        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                        req.timeoutInterval = 60 * 15
                        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
                        do {
                            (bytes, response) = try await session.bytes(for: req, delegate: redirects)
                        } catch {
                            throw RelayError.transport((error as NSError).localizedDescription)
                        }
                        try Self.check(response, Data())
                        return bytes
                    }
                    var parser = SSEParser(lastEventID: String(after))
                    var buffer: [UInt8] = []
                    var chunk: [UInt8] = []
                    chunk.reserveCapacity(1024)
                    for try await byte in bytes {
                        chunk.append(byte)
                        if byte == 0x0A {
                            for line in SSEParser.lines(from: chunk, buffer: &buffer) {
                                if let msg = parser.feed(line: line), let event = RelayEvent(message: msg) {
                                    continuation.yield(event)
                                }
                            }
                            chunk.removeAll(keepingCapacity: true)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
