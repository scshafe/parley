import Foundation
import ParleyKit
import SwiftData

/// A small local cache of conversations and turns (text and timings), so a
/// conversation opens offline. The relay holds the full record.
@Model
final class CachedConversation {
    @Attribute(.unique) var id: String
    var title: String
    var updatedAt: String

    init(id: String, title: String, updatedAt: String) {
        self.id = id
        self.title = title
        self.updatedAt = updatedAt
    }
}

@Model
final class CachedTurn {
    @Attribute(.unique) var id: String
    var conversationID: String
    var seq: Int
    var json: Data
    var timings: Data?

    init(id: String, conversationID: String, seq: Int, json: Data, timings: Data? = nil) {
        self.id = id
        self.conversationID = conversationID
        self.seq = seq
        self.json = json
        self.timings = timings
    }

    var turn: ParleyKit.Turn? { try? ParleyJSON.decoder.decode(ParleyKit.Turn.self, from: json) }
}

@MainActor
enum CacheStore {
    static func makeContainer(inMemory: Bool) -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: inMemory)
        do {
            return try ModelContainer(for: CachedConversation.self, CachedTurn.self, configurations: config)
        } catch {
            // A cache that cannot open is rebuilt in memory: it is only a cache.
            return try! ModelContainer(for: CachedConversation.self, CachedTurn.self,
                                       configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        }
    }

    static func save(conversations: [Conversation], in context: ModelContext) {
        for c in conversations {
            let id = c.id
            let existing = try? context.fetch(FetchDescriptor<CachedConversation>(predicate: #Predicate { $0.id == id })).first
            if let existing {
                existing.title = c.displayTitle
                existing.updatedAt = c.updatedAt
            } else {
                context.insert(CachedConversation(id: c.id, title: c.displayTitle, updatedAt: c.updatedAt))
            }
        }
        try? context.save()
    }

    static func cachedConversations(in context: ModelContext) -> [CachedConversation] {
        (try? context.fetch(FetchDescriptor<CachedConversation>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]))) ?? []
    }

    static func save(turns: [ParleyKit.Turn], in context: ModelContext) {
        for t in turns {
            guard let data = try? ParleyJSON.encoder.encode(t) else { continue }
            let id = t.id
            let existing = try? context.fetch(FetchDescriptor<CachedTurn>(predicate: #Predicate { $0.id == id })).first
            if let existing {
                existing.json = data
            } else {
                context.insert(CachedTurn(id: t.id, conversationID: t.conversationId, seq: t.seq, json: data))
            }
        }
        try? context.save()
    }

    static func cachedTurns(conversationID: String, in context: ModelContext) -> [ParleyKit.Turn] {
        let descriptor = FetchDescriptor<CachedTurn>(predicate: #Predicate { $0.conversationID == conversationID },
                                                     sortBy: [SortDescriptor(\.seq)])
        return ((try? context.fetch(descriptor)) ?? []).compactMap(\.turn)
    }

    static func timings(turnID: String, in context: ModelContext) -> Data? {
        try? context.fetch(FetchDescriptor<CachedTurn>(predicate: #Predicate { $0.id == turnID })).first?.timings
    }

    static func save(timings: Data, turnID: String, in context: ModelContext) {
        if let row = try? context.fetch(FetchDescriptor<CachedTurn>(predicate: #Predicate { $0.id == turnID })).first {
            row.timings = timings
            try? context.save()
        }
    }
}

/// Recent replies' audio, in Caches; kept 7 days on the phone (decision P-Q5).
enum AudioCache {
    static var directory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("ReplyAudio")
    }

    static func file(for turnID: String) -> URL {
        directory.appendingPathComponent("\(turnID).wav")
    }

    static func prune(olderThanDays days: Int) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return
        }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        for f in files {
            let date = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if date < cutoff { try? fm.removeItem(at: f) }
        }
    }
}
