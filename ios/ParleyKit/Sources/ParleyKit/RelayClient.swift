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
}

public enum RelayError: Error, Equatable, LocalizedError {
    case notConfigured
    case unauthorized
    case http(status: Int, code: String, detail: String)
    case badResponse
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured: return "Set the relay URL and token in Settings."
        case .unauthorized: return "The relay refused the token."
        case .http(let status, let code, let detail): return "The relay answered \(status) \(code): \(detail)"
        case .badResponse: return "The relay's answer could not be read."
        case .transport(let what): return "The relay could not be reached (\(what))."
        }
    }
}

/// The relay's API, for the app. Every call carries the bearer token.
public final class RelayClient: @unchecked Sendable {
    public let configuration: RelayConfiguration
    private let session: URLSession

    public init(configuration: RelayConfiguration, session: URLSession = .shared) {
        self.configuration = configuration
        self.session = session
    }

    public func url(_ path: String) -> URL {
        // Paths from the relay are absolute ("/api/v1/..."); keep any base path.
        var base = configuration.baseURL.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        return URL(string: base + (path.hasPrefix("/") ? path : "/" + path))!
    }

    func request(_ path: String, method: String = "GET", body: Data? = nil) -> URLRequest {
        var req = URLRequest(url: url(path))
        req.httpMethod = method
        req.setValue("Bearer \(configuration.token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        req.timeoutInterval = 30
        return req
    }

    func send<T: Decodable>(_ req: URLRequest, as type: T.Type) async throws -> T {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw RelayError.transport((error as NSError).localizedDescription)
        }
        try Self.check(response, data)
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
        try await send(request("/api/v1/conversations"), as: ConversationList.self).conversations
    }

    public func createConversation(title: String? = nil) async throws -> Conversation {
        let body = try JSONSerialization.data(withJSONObject: title.map { ["title": $0] } ?? [String: String]())
        return try await send(request("/api/v1/conversations", method: "POST", body: body), as: Conversation.self)
    }

    public func conversation(id: String) async throws -> Conversation {
        try await send(request("/api/v1/conversations/\(id)"), as: Conversation.self)
    }

    // MARK: Turns

    /// Send a turn. A retry with the same `clientTurnID` is safe: the relay
    /// answers the turn it already has.
    public func sendTurn(conversationID: String, text: String, clientTurnID: String) async throws -> Turn {
        let body = try JSONSerialization.data(withJSONObject: ["text": text, "client_turn_id": clientTurnID])
        return try await send(request("/api/v1/conversations/\(conversationID)/turns", method: "POST", body: body),
                              as: Turn.self)
    }

    public func turn(conversationID: String, turnID: String) async throws -> Turn {
        try await send(request("/api/v1/conversations/\(conversationID)/turns/\(turnID)"), as: Turn.self)
    }

    public func timingsData(for turn: Turn) async throws -> Data {
        guard let path = turn.timingsUrl else { throw RelayError.badResponse }
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request(path))
        } catch {
            throw RelayError.transport((error as NSError).localizedDescription)
        }
        try Self.check(response, data)
        return data
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
        let (tmp, response): (URL, URLResponse)
        do {
            (tmp, response) = try await session.download(for: request(path))
        } catch {
            throw RelayError.transport((error as NSError).localizedDescription)
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let data = (try? Data(contentsOf: tmp)) ?? Data()
            try Self.check(response, data)
        }
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.moveItem(at: tmp, to: destination)
    }

    // MARK: Events

    /// The conversation's `turn.updated` events after `after`, as they happen.
    /// The stream ends when the relay closes it (every 10 minutes) or on error;
    /// the caller reconnects with the last event id.
    public func events(conversationID: String, after: Int) -> AsyncThrowingStream<RelayEvent, Error> {
        var req = request("/api/v1/conversations/\(conversationID)/events?after=\(after)")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 60 * 15
        let session = self.session
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: req)
                    try Self.check(response, Data())
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
