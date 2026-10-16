import Foundation

public struct RelayConfiguration: Equatable, Sendable {
    public var baseURL: URL
    public var token: String

    public init(baseURL: URL, token: String) {
        self.baseURL = baseURL
        self.token = token
    }

    /// Parse a relay URL typed in settings: `https://relay.example.ts.net`,
    /// or `http://` for a local dev relay. A bare host gets `https://`.
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
        case .notConfigured: return "Set the relay URL in Settings, and sign in or set a dev token."
        case .unauthorized: return "The relay refused this app's credentials. Check the dev token, or sign in again in Settings."
        case .signInRequired: return "Your sign-in has ended. Sign in again in Settings."
        case .http(let status, let code, let detail): return "The relay answered \(status) \(code): \(detail)"
        case .badResponse: return "The relay's answer could not be read."
        case .transport(let what): return "The relay could not be reached (\(what))."
        }
    }
}

/// Where the relay client gets its bearer token: a fixed dev token, or the
/// signed-in session that refreshes its access token (`TokenSession`).
public protocol BearerProvider: Sendable {
    /// The token to send now. A session refreshes one that is about to expire.
    func currentToken() async throws -> String
    /// After the relay refused `rejected` (401): a different token to retry
    /// with once, or `nil` when there is none. Throws `RelayError.signInRequired`
    /// when the session has ended.
    func tokenAfterRejection(_ rejected: String) async throws -> String?
}

/// A fixed token: the dev relay's, or P1's static bearer.
public struct StaticBearer: BearerProvider {
    public let token: String

    public init(token: String) {
        self.token = token
    }

    public func currentToken() async throws -> String {
        guard !token.isEmpty else { throw RelayError.notConfigured }
        return token
    }

    public func tokenAfterRejection(_ rejected: String) async throws -> String? { nil }
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

    public convenience init(configuration: RelayConfiguration, session: URLSession = .shared) {
        self.init(baseURL: configuration.baseURL, auth: StaticBearer(token: configuration.token), session: session)
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
