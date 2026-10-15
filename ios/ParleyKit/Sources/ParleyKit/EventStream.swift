import Foundation

/// A server-sent events parser (the subset the relay uses: `id`, `event`,
/// `data`, comments and `retry`). Feed it lines without their line ending; a
/// blank line dispatches the event being built.
public struct SSEParser: Sendable {
    public struct Message: Equatable, Sendable {
        public var id: String?
        public var event: String
        public var data: String
    }

    private var id: String?
    private var event = ""
    private var data: [String] = []
    public private(set) var lastEventID: String?
    public private(set) var retryMs: Int?

    public init(lastEventID: String? = nil) {
        self.lastEventID = lastEventID
    }

    public mutating func feed(line rawLine: String) -> Message? {
        let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
        if line.isEmpty {
            defer {
                id = nil
                event = ""
                data = []
            }
            guard !data.isEmpty else { return nil }
            if let id { lastEventID = id }
            return Message(id: id, event: event.isEmpty ? "message" : event, data: data.joined(separator: "\n"))
        }
        if line.hasPrefix(":") { return nil }
        let field: Substring
        var value: Substring
        if let colon = line.firstIndex(of: ":") {
            field = line[..<colon]
            value = line[line.index(after: colon)...]
            if value.hasPrefix(" ") { value = value.dropFirst() }
        } else {
            field = Substring(line)
            value = ""
        }
        switch field {
        case "id": id = String(value)
        case "event": event = String(value)
        case "data": data.append(String(value))
        case "retry": retryMs = Int(value)
        default: break
        }
        return nil
    }

    /// Split a chunk of bytes into lines, keeping a partial last line in `buffer`.
    public static func lines(from bytes: [UInt8], buffer: inout [UInt8]) -> [String] {
        var out: [String] = []
        for b in bytes {
            if b == 0x0A {
                out.append(String(decoding: buffer, as: UTF8.self))
                buffer.removeAll(keepingCapacity: true)
            } else {
                buffer.append(b)
            }
        }
        return out
    }
}

extension RelayEvent {
    /// A relay event from an SSE message; `nil` for a message the app does not use.
    public init?(message: SSEParser.Message) {
        guard message.event == "turn.updated",
              let turn = try? ParleyJSON.decoder.decode(Turn.self, from: Data(message.data.utf8)) else {
            return nil
        }
        self.init(id: message.id.flatMap { Int($0) }, type: message.event, turn: turn)
    }
}
