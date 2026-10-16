import Foundation

nonisolated struct EntryRoute: Identifiable { let id: String }

func journalDate(_ date: Date = .now) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: date)
}

nonisolated func journalDay(_ value: String) -> Date {
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

nonisolated enum TaskType: String, Codable, Sendable {
    case transcribe, organize, analyze, indexDream = "index_dream", matchPatterns = "match_patterns", refreshFindings = "refresh_findings", generateImage = "generate_image", generateVideo = "generate_video", unknown
    init(from decoder: any Decoder) throws { self = TaskType(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown }
}

nonisolated enum TaskStatus: String, Codable, Sendable {
    case waiting, running, completed, failed, canceled, obsolete, unknown
    init(from decoder: any Decoder) throws { self = TaskStatus(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown }
}

nonisolated struct TaskInfo: Codable, Sendable, Identifiable {
    var id: String
    var type: TaskType
    var status: TaskStatus
    var errorCode: String?
    var dreamId: String?
    var subjectId: String?
    var sourceRevision: Int?
    var updatedAt: Date
    var inProgress: Bool { status == .waiting || status == .running }
    var limited: Bool { status == .failed && (errorCode == "cap_reached" || errorCode == "ceiling_reached") }
}

nonisolated struct TaskResponse: Decodable { var task: TaskInfo }

nonisolated enum OutputStatus: String, Codable, Sendable {
    case current, outdated, unknown
    init(from decoder: any Decoder) throws { self = OutputStatus(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown }
}

nonisolated enum TagCategory: String, Codable, Sendable {
    case person, place, object, action, emotion, theme, unknown
    init(from decoder: any Decoder) throws { self = TagCategory(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown }
}

nonisolated enum Feeling: String, Codable, Sendable {
    case stated, inferred, unknown
    init(from decoder: any Decoder) throws { self = Feeling(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown }
}

nonisolated struct Tag: Codable, Sendable, Identifiable {
    var category: TagCategory
    var text: String
    var originalText: String
    var excerpt: String
    var feeling: Feeling?
    var corrected: Bool
    var removed: Bool
    var id: String { "\(category.rawValue):\(originalText)" }
}

nonisolated struct Organization: Codable, Sendable {
    var status: OutputStatus
    var dreamRevision: Int
    var summary: String
    var summaryCorrected: Bool
    var tags: [Tag]
    var createdAt: Date
}

nonisolated struct DreamCorrection: Encodable { var category: String; var originalText: String?; var text: String }

nonisolated enum ServerStatus: String, Codable, Sendable {
    case ready, processing, attention, unknown
    init(from decoder: any Decoder) throws { self = ServerStatus(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown }
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
    var status: ServerStatus
    var favoriteVisualId: String?
    var updatedAt: Date
}

nonisolated struct JournalPage: Decodable { var items: [JournalItem]; var hasMore: Bool }
nonisolated struct DreamResponse: Decodable { var dream: Dream }

nonisolated struct JournalFilter: Encodable, Equatable {
    var query = ""
    var tag: String?
    var mood: Mood?
    var fromDate: String?
    var toDate: String?
    var isEmpty: Bool { query.isEmpty && tag == nil && mood == nil && fromDate == nil && toDate == nil }
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

nonisolated enum JournalStatus { case unsentDraft, needsAttention, processing, saved }

nonisolated struct JournalRow: Identifiable {
    var id: String
    var item: JournalItem?
    var draft: Draft?
    var status: JournalStatus {
        if draft?.unsent == true { .unsentDraft }
        else if item?.status == .attention { .needsAttention }
        else if item?.status == .processing { .processing }
        else { .saved }
    }
    // A row without a loaded server item is a draft and opens in the editor; every loaded dream opens its own screen.
    var opensEditor: Bool { item == nil }
    var statusText: String {
        switch status {
        case .unsentDraft: draft?.conflict == true ? "Saved on this device · Needs your review" : "Saved on this device · Waiting to sync"
        case .needsAttention: "Synced · Needs attention"
        case .processing: "Synced · Summary on its way"
        case .saved: "Synced"
        }
    }
    var title: String { draft?.title ?? item?.title ?? "Untitled dream" }
    var preview: String { draft?.text ?? item?.summary ?? item?.preview ?? "" }
    var date: String { draft?.dreamDate ?? item?.dreamDate ?? "" }
}
