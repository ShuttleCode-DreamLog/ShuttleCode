import Foundation

func newID() -> String { UUID().uuidString.lowercased() }

nonisolated struct Me: Codable, Sendable {
    var userId: String
    var timezone: String?
    var reminderWeekday: Int?
    var useHistory: Bool
    var limits: Limits
    var usage: [Usage]
    var checkinKeepDays: Int
}

nonisolated struct Usage: Codable, Sendable { var kind: String; var used: Int; var cap: Int }

nonisolated struct Limits: Codable, Sendable {
    var maxDreamChars = 20000
    var maxTitleChars = 120
    var maxMemoryChars = 2000
    var maxMessageChars = 2000
    var maxSummaryChars = 600
    var maxTagChars = 60
    var maxLabelChars = 60
    var maxPatternNoteChars = 300
    var maxAdjustmentChars = 300
    var maxSceneChars = 4000
    var maxRecordingSeconds = 600
    var maxAudioBytes = 10000000
}

nonisolated struct SettingsSave: Encodable, Sendable {
    var timezone: String
    var reminderWeekday: Int?
    var useHistory: Bool
    enum CodingKeys: String, CodingKey { case timezone, reminderWeekday = "reminder_weekday", useHistory = "use_history" }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(timezone, forKey: .timezone)
        try container.encode(reminderWeekday, forKey: .reminderWeekday)
        try container.encode(useHistory, forKey: .useHistory)
    }
}

nonisolated enum APIError: Error, Equatable {
    case noticeRequired, notSent, noAnswer, decoding, interrupted
    case server(status: Int, code: String, message: String)
    var uncertainSave: Bool {
        switch self {
        case .noAnswer, .decoding, .interrupted: true
        case let .server(status, code, _): status >= 500 || code == "unreadable"
        default: false
        }
    }
    var code: String? { if case let .server(_, code, _) = self { code } else { nil } }
    var message: String {
        switch self {
        case .noticeRequired: "Read and acknowledge the privacy notice first."
        case .notSent: "Could not connect. Check the server address, connection and certificate trust."
        case .noAnswer: "No answer arrived. Try again."
        case .decoding: "The server response could not be read."
        case .interrupted: "The request was interrupted."
        case let .server(_, _, message): message
        }
    }
}

nonisolated struct ServerError: Decodable { var error: String; var message: String; var currentRevision: Int? }
nonisolated enum IdentityError: Error { case keychainFailed(status: Int32), invalidIdentity }
nonisolated enum StoreError: Error { case openFailed, statementFailed(code: Int32), filesFailed }

nonisolated struct Permissions: Codable, Sendable {
    var transcription = true
    var analysis = true
    var discussion = true
    var history = true
    var patterns = true
    var visuals = true
}

nonisolated enum DreamSource: String, Codable, Sendable {
    case text, voice, unknown
    init(from decoder: any Decoder) throws { self = DreamSource(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown }
}
