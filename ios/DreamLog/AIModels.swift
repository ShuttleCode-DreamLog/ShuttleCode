import Foundation

nonisolated enum SectionKind: String, Codable, Sendable {
    case whatHappened = "what_happened", emotionalMovement = "emotional_movement", wakingLifeConnections = "waking_life_connections"
    case themesAndReadings = "themes_and_readings", threatAndResponse = "threat_and_response", relatedDreams = "related_dreams"
    case reflectionQuestions = "reflection_questions", unknown
    init(from decoder: any Decoder) throws { self = SectionKind(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown }
    var heading: String {
        switch self {
        case .whatHappened: "What happened"
        case .emotionalMovement: "How the feelings moved"
        case .wakingLifeConnections: "Possible links to waking life"
        case .themesAndReadings: "Possible meanings"
        case .threatAndResponse: "Threat and response"
        case .relatedDreams: "Related dreams"
        case .reflectionQuestions: "Questions to reflect on"
        case .unknown: "Reflection"
        }
    }
}

nonisolated enum SourceKind: String, Codable, Sendable {
    case dream, memory, output, notes, unknown
    init(from decoder: any Decoder) throws { self = SourceKind(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown }
}

nonisolated struct AnalysisSection: Codable, Sendable { var kind: SectionKind; var text: String; var citations: [String] }

nonisolated struct ContextEntry: Codable, Sendable, Identifiable {
    var label: String
    var kind: SourceKind
    var sourceId: String
    var sourceRevision: Int
    var sourceDate: String?
    var available: Bool
    var cutTo: Int?
    var id: String { label }
    // Labels are never shown to the user (wiki 4.6.7, analysis logic 4).
    var name: String {
        let date = sourceDate.map { " · \(displayDate($0))" } ?? ""
        return switch (kind, label) {
        case (.dream, "DREAM"): "This dream"
        case (.dream, _): "Dream\(date)"
        case (.output, "ANALYSIS"): "This dream's analysis"
        case (.output, _): "This dream's summary and tags"
        case (.memory, _): "Life note\(date)"
        case (.notes, _): "Your correction notes"
        case (.unknown, _): "Source"
        }
    }
}

nonisolated struct Analysis: Codable, Sendable {
    var id: String
    var status: OutputStatus
    var dreamRevision: Int
    var sections: [AnalysisSection]
    var withheld: Int
    var context: [ContextEntry]
    var removedSources: Int
    var dreamDate: String
    var mood: Mood?
    var model: String
    var instructionVersion: String
    var createdAt: Date
    func text(of section: AnalysisSection) -> String {
        context.reduce(section.text) { text, entry in text.replacingOccurrences(of: "[\(entry.label)]", with: entry.name) }
    }
    func sources(of section: AnalysisSection) -> [String] {
        section.citations.map { label in context.first { $0.label == label }?.name ?? "A source that has since changed" }
    }
}

nonisolated struct AnalysisResponse: Decodable { var analysis: Analysis?; var task: TaskInfo? }
nonisolated struct RefreshRequest: Encodable { var refreshId: String }

nonisolated struct Period: Codable, Sendable { var fromDate: String; var toDate: String }

nonisolated enum FindingKind: String, Codable, Sendable {
    case recurring, related, unknown
    init(from decoder: any Decoder) throws { self = FindingKind(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown }
}

nonisolated enum FindingStatus: String, Codable, Sendable {
    case current, refreshing, unknown
    init(from decoder: any Decoder) throws { self = FindingStatus(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown }
}

nonisolated enum Trend: String, Codable, Sendable {
    case moreOftenRecordedRecently = "more_often_recorded_recently", lessOftenRecordedRecently = "less_often_recorded_recently", same, unknown
    init(from decoder: any Decoder) throws { self = Trend(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown }
}

nonisolated struct FindingExample: Codable, Sendable, Identifiable {
    var dreamId: String
    var dreamDate: String
    var title: String?
    var category: TagCategory
    var description: String
    var excerpt: String
    var sharedElement: String?
    var difference: String?
    var id: String { dreamId }
    var name: String { title ?? "Dream of \(displayDate(dreamDate))" }
}

nonisolated struct DismissalNote: Codable, Sendable { var dreamId: String; var note: String }

nonisolated struct Finding: Codable, Sendable, Identifiable {
    var groupId: String
    var label: String?
    var labelCorrected: Bool
    var kind: FindingKind
    var status: FindingStatus
    var explanation: String?
    var supportingDreams: Int
    var periodCount: Int
    var previousCount: Int
    var trend: Trend?
    var examples: [FindingExample]
    var notes: [String]
    var dismissalNotes: [DismissalNote]
    var id: String { groupId }
    var name: String { label ?? "Unnamed theme" }
    // The server lists one example per matched tag, so a dream with two tags in the group comes twice; the screens act per dream.
    var dreams: [FindingExample] { var seen = Set<String>(); return examples.filter { seen.insert($0.dreamId).inserted } }
}

nonisolated struct PatternsResponse: Codable, Sendable {
    var available: Bool
    var period: Period
    var eligibleDreams: Int
    var previousEligibleDreams: Int
    var findings: [Finding]
    var insufficientHistory: Bool
    var task: TaskInfo?
}

// An empty label removes the user's own name and shows the generated one again.
nonisolated struct PatternLabel: Encodable { var label: String }
nonisolated struct PatternDismissal: Encodable { var dreamId: String; var note: String }
nonisolated struct PatternSplit: Encodable { var dreamIds: [String]; var label: String?; var note: String }

// The daily limits reset at 00:00 UTC; the app names that moment in the phone's time (wiki 4.4.6).
func limitReset(_ now: Date = .now) -> String {
    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = .gmt
    let reset = utc.date(byAdding: .day, value: 1, to: utc.startOfDay(for: now)) ?? now
    return reset.formatted(date: .omitted, time: .shortened)
}

// Wording of failed work from its error code (wiki 4.4.6). No wording blames the dream or suggests changing it.
func failureText(_ task: TaskInfo) -> String { failureText(task.errorCode, task.type) }

func failureText(_ code: String?, _ type: TaskType) -> String {
    switch (code, type) {
    case ("cap_reached", _): "Today's limit for this kind of generation is used up. It resets at \(limitReset())."
    case ("ceiling_reached", _): "DreamLog has reached today's limit for everyone. It resets at \(limitReset())."
    case ("rate_limited", _): "The AI service is busy. Try again later."
    case ("provider_config", _): "The AI service is not set up correctly on the DreamLog server at the moment. This has nothing to do with your dream, and the team has to put it right. The work is tried again when the server next starts."
    case ("provider_refused", .organize): "The AI service did not accept this dream for a summary and tags. The dream is saved unchanged and can be read and edited."
    case ("provider_refused", .analyze): "The AI service did not accept this dream for an analysis. The dream is saved unchanged."
    case ("provider_refused", .matchPatterns): "The AI service did not accept this dream for a comparison with your other dreams. The dream is saved unchanged and can be read and edited."
    default: "The work could not be completed."
    }
}

nonisolated enum MessageRole: String, Codable, Sendable {
    case user, assistant, unknown
    init(from decoder: any Decoder) throws { self = MessageRole(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown }
}

nonisolated enum MessageState: String, Codable, Sendable {
    case ok, stale, unknown
    init(from decoder: any Decoder) throws { self = MessageState(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown }
}

// A hint from the model only: both actions are on every message the user wrote, whatever it said (wiki 4.6.6, rule 3).
nonisolated enum Offer: String, Codable, Sendable {
    case addToDream = "add_to_dream", rememberInProfile = "remember_in_profile", unknown
    init(from decoder: any Decoder) throws { self = Offer(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown }
}

nonisolated struct Message: Codable, Sendable, Identifiable {
    var id: String
    var seq: Int
    var role: MessageRole
    var text: String
    var state: MessageState
    var replyTo: String?
    var offer: Offer?
    var context: [ContextEntry]
    var createdAt: Date
}

nonisolated struct Correction: Codable, Sendable, Identifiable {
    var id: String
    var messageId: String?
    var section: SectionKind?
    var outputId: String?
    var note: String
    var createdAt: Date
}

nonisolated struct Conversation: Codable, Sendable {
    var dreamId: String
    var goal: String?
    var messages: [Message]
    var corrections: [Correction]
    var analysisWithheld: Bool
}

nonisolated struct ConversationResponse: Decodable { var conversation: Conversation }
nonisolated struct TurnRequest: Encodable { var messageId: String; var text: String }
nonisolated struct TurnStart: Decodable { var contextRestarted: Bool }
nonisolated struct TurnDelta: Decodable { var text: String }
nonisolated struct TurnDone: Codable, Sendable { var userMessage: Message; var message: Message }

// The events of one streamed turn (wiki 4.2.5); a stream that closes before `done` or `error` arrives as `failed(.interrupted)`.
nonisolated enum TurnEvent: Sendable {
    case start(contextRestarted: Bool)
    case delta(String)
    case done(TurnDone)
    case failed(APIError)
}

nonisolated enum PendingState: Sendable { case sending, failed, stillWorking }
nonisolated struct PendingTurn: Sendable { var messageId: String; var text: String; var state: PendingState }

// Shown under every reply that did not arrive, whatever the reason, because the app cannot know what the message said (wiki 4.4.6).
let dangerLine = "If you wrote about being in danger or about harming yourself: DreamLog cannot help with that. Please contact your local emergency services or someone you trust."

func turnFailureText(_ error: APIError) -> String {
    switch error.code {
    case "cap_reached", "ceiling_reached", "rate_limited": failureText(error.code, .analyze)
    case "provider_refused": "The AI service did not answer this message. Your message is kept, and you can write another."
    case "context_changed": "The dream or its context changed while the reply was written. Request it again."
    case "not_permitted": "Discussion is off for this dream."
    default: error == .interrupted ? "The reply was interrupted." : error.message
    }
}
