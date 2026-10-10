import Foundation

nonisolated struct EntryRoute: Identifiable { let id: String }

func journalDate(_ date: Date = .now) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: date)
}

func journalDay(_ value: String) -> Date {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.date(from: value) ?? .now
}

nonisolated enum Mood: String, Codable, CaseIterable, Sendable {
    case calm, happy, excited, confused, sad, anxious, afraid, angry, unknown
    init(from decoder: any Decoder) throws { self = Mood(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown }
}

nonisolated struct Dream: Codable, Sendable, Identifiable {
    var id: String
    var text: String
    var revision: Int
    var dreamDate: String
    var title: String?
    var mood: Mood?
    var source: DreamSource
    var audioStatus: String
    var audioMs: Int?
    var heardText: String?
    var permissions: Permissions
    var tasks: [TaskInfo]
    var organization: Organization?
    var createdAt: Date
    var updatedAt: Date
}

nonisolated struct TaskInfo: Codable, Sendable {
    var id: String
    var type: String
    var status: String
}
nonisolated struct Organization: Codable, Sendable {
    var status: String
    var dreamRevision: Int
    var summary: String
}

nonisolated struct JournalItem: Codable, Sendable, Identifiable {
    var id: String
    var dreamDate: String
    var title: String?
    var mood: Mood?
    var revision: Int
    var audioStatus: String
    var preview: String
    var summary: String?
    var status: String
    var favoriteVisualId: String?
    var updatedAt: Date
}

nonisolated struct JournalPage: Decodable { var items: [JournalItem]; var hasMore: Bool }
nonisolated struct DreamResponse: Decodable { var dream: Dream }

nonisolated struct JournalFilter: Encodable {
    var query = ""
    var mood: Mood?
    var fromDate: String?
    var toDate: String?
    var isEmpty: Bool { query.isEmpty && mood == nil && fromDate == nil && toDate == nil }
}

nonisolated struct Draft: Codable, Sendable {
    var dreamId: String
    var text = ""
    var title: String?
    var mood: Mood?
    var dreamDate: String
    var source: DreamSource = .text
    var permissions = Permissions()
    var baseRevision = 0
    var unsent = true
    var conflict = false
    var audioFile: String?
    var audioMs: Int?
    var audioUploaded = false
    var audioSendStarted = false
    var unconfirmed = false
    var sentText: String?
    var updatedAt = Date.now

    init(dreamId: String, dreamDate: String) { self.dreamId = dreamId; self.dreamDate = dreamDate }
    init(dream: Dream) {
        dreamId = dream.id; text = dream.text; title = dream.title; mood = dream.mood
        dreamDate = dream.dreamDate; source = dream.source; permissions = dream.permissions
        baseRevision = dream.revision; unsent = false
    }
    var save: DreamSave { DreamSave(baseRevision: baseRevision, text: text, dreamDate: dreamDate, title: title, mood: mood, source: source, permissions: baseRevision == 0 ? permissions : nil) }
    func matches(_ dream: Dream) -> Bool { text == dream.text && title == dream.title && mood == dream.mood && dreamDate == dream.dreamDate }
}

nonisolated struct DreamSave: Encodable {
    var baseRevision: Int
    var text: String
    var dreamDate: String
    var title: String?
    var mood: Mood?
    var source: DreamSource
    var permissions: Permissions?
    enum CodingKeys: String, CodingKey { case baseRevision = "base_revision", text, dreamDate = "dream_date", title, mood, source, permissions }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(baseRevision, forKey: .baseRevision)
        try container.encode(text, forKey: .text)
        try container.encode(dreamDate, forKey: .dreamDate)
        try container.encode(title, forKey: .title)
        try container.encode(mood, forKey: .mood)
        try container.encode(source, forKey: .source)
        if let permissions { try container.encode(permissions, forKey: .permissions) }
    }
}

nonisolated struct JournalRow: Identifiable {
    var id: String
    var item: JournalItem?
    var draft: Draft?
    var status: String {
        if draft?.unsent == true { "Unsent draft" }
        else if item?.status == "attention" { "Needs attention" }
        else if item?.status == "processing" { "Processing" }
        else { "Saved" }
    }
    var title: String { draft?.title ?? item?.title ?? "Untitled journal" }
    var preview: String { draft?.text ?? item?.summary ?? item?.preview ?? "" }
    var date: String { draft?.dreamDate ?? item?.dreamDate ?? "" }
}
