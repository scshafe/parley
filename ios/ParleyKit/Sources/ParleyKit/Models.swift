import Foundation

/// A turn's state on the relay: `thinking` (the agent is answering), `speaking`
/// (voice-lab is rendering), `ready` (audio and timings can be fetched) or
/// `failed`.
public enum TurnState: String, Codable, Sendable, CaseIterable {
    case thinking
    case speaking
    case ready
    case failed

    public var isFinished: Bool { self == .ready || self == .failed }

    public var label: String {
        switch self {
        case .thinking: return "Thinking"
        case .speaking: return "Speaking"
        case .ready: return "Ready"
        case .failed: return "Failed"
        }
    }

    /// Decodes an unknown future state as `.thinking` rather than failing.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = TurnState(rawValue: raw) ?? .thinking
    }
}

public struct TurnAudio: Codable, Hashable, Sendable {
    public var url: String
    public var contentType: String
    public var durationMs: Int?
    public var available: Bool

    public init(url: String, contentType: String = "audio/wav", durationMs: Int?, available: Bool = true) {
        self.url = url
        self.contentType = contentType
        self.durationMs = durationMs
        self.available = available
    }
}

public struct RelayErrorInfo: Codable, Hashable, Sendable {
    public var code: String
    public var detail: String
}

public struct Turn: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var conversationId: String
    public var seq: Int
    public var clientTurnId: String
    public var state: TurnState
    public var userText: String
    public var replyText: String?
    public var attachment: String?
    public var styleVersion: String?
    public var audio: TurnAudio?
    public var timingsUrl: String?
    public var error: RelayErrorInfo?
    public var createdAt: String
    public var updatedAt: String

    public init(id: String, conversationId: String, seq: Int, clientTurnId: String, state: TurnState,
                userText: String, replyText: String? = nil, attachment: String? = nil, styleVersion: String? = nil,
                audio: TurnAudio? = nil, timingsUrl: String? = nil, error: RelayErrorInfo? = nil,
                createdAt: String = "", updatedAt: String = "") {
        self.id = id
        self.conversationId = conversationId
        self.seq = seq
        self.clientTurnId = clientTurnId
        self.state = state
        self.userText = userText
        self.replyText = replyText
        self.attachment = attachment
        self.styleVersion = styleVersion
        self.audio = audio
        self.timingsUrl = timingsUrl
        self.error = error
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct TurnSummary: Codable, Hashable, Sendable {
    public var id: String
    public var state: TurnState
    public var userText: String
    public var replyText: String?
}

public struct Conversation: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var title: String?
    public var createdAt: String
    public var updatedAt: String
    public var turnCount: Int
    public var lastEventId: Int
    public var lastTurn: TurnSummary?
    /// Present when the conversation is fetched on its own.
    public var turns: [Turn]?
    /// Present in search results: the text around the first match.
    public var snippet: String?

    public var displayTitle: String {
        if let title, !title.isEmpty { return title }
        return "New conversation"
    }
}

/// The relay's answer to a device registration. `push` is whether the relay
/// can send pushes now (false until it has an APNs key).
public struct DeviceRegistration: Codable, Equatable, Sendable {
    public var id: String
    public var environment: String?
    public var push: Bool?
}

struct ConversationList: Codable {
    var conversations: [Conversation]
}

struct ErrorEnvelope: Codable {
    var error: RelayErrorInfo
}

/// A `turn.updated` event from a conversation's event stream.
public struct RelayEvent: Sendable, Equatable {
    public var id: Int?
    public var type: String
    public var turn: Turn?
}

public enum ParleyJSON {
    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.outputFormatting = [.sortedKeys]
        return e
    }()
}

/// A new idempotency id for a turn: a retry of the same send reuses it.
public func makeClientTurnID() -> String {
    "ios-" + UUID().uuidString.lowercased()
}
