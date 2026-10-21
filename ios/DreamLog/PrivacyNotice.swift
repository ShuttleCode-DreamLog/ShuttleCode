import SwiftUI
import CryptoKit

let noticeVersion = 4
let noticeKey = "notice-version"
let noticeContentKey = "notice-content-fingerprint"
let noticeIntroduction = "Development build: summaries, tags, analyses and patterns are made by an AI service on the server; recording is unavailable. Read how this project handles your data."
let deletionKey = "deletion-started"
let reminderKey = "reminder-weekday"
let answeredOffersKey = "answered-offers"

struct PrivacyPart: Identifiable {
    let title: String
    let text: String
    var id: String { title }
}

let privacyParts: [PrivacyPart] = [
    .init(title: "AI", text: "A dream's text, date and mood are sent to Google's Gemini models on Vertex AI for a summary, tags, an analysis and comparisons with your other dreams. Life notes and earlier dreams you allow are sent as analysis context, and corrections you type are sent too. The server sends them through the team's Google Cloud project, whose terms do not let Google train its models on them. While DreamLog is a course project, enter only invented sample dreams."),
    .init(title: "Deletion", text: "Deleting a record removes our stored copy, not data the AI provider keeps under its own terms."),
    .init(title: "Storage", text: "Journals, notes and profile fields are stored on the project server; its operators can read them."),
    .init(title: "Permissions", text: "The history switch is in Settings and on Life Notes. Each dream has six AI switches and Keep out of AI processing; each note has Allow AI use. Microphone permission will be managed in iOS Settings when recording is available."),
    .init(title: "Recordings", text: "Recording is unavailable. Planned server audio is deleted after a usable transcript is stored, transcription is turned off, or the dream is deleted. The phone keeps its copy until you see the transcript and its draft is sent, unless you discard/delete it. Failed transcription keeps audio; deleted audio cannot be replayed."),
    .init(title: "Project", text: "Delete my journal removes this device’s entire server journal, local data and identity. The project plan is to delete remaining server journals at course end; the date and cleanup must be confirmed before public release.")
]

// Content changes require consent even when a version bump is accidentally omitted.
let noticeFingerprint = SHA256.hash(data: Data(([noticeIntroduction] + privacyParts.flatMap { [$0.title, $0.text] }).joined(separator: "\u{0}").utf8))
    .map { String(format: "%02x", $0) }.joined()

struct PrivacyText: View {
    var body: some View {
        ForEach(privacyParts) { part in
            VStack(alignment: .leading, spacing: 4) {
                Text(part.title).font(.callout.weight(.semibold))
                Text(part.text).font(.callout)
            }
        }
    }
}

struct PrivacyNoticeView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 13) {
                Eyebrow("Before you begin")
                Text(noticeIntroduction).font(.callout)
                PrivacyText()
                Button("I acknowledge this notice") { Task { await model.acknowledgeNotice() } }.buttonStyle(.primaryWide).padding(.top, 8)
                if model.hasPriorAcknowledgment { DeleteJournalButton() }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
        .dreamPage()
        .page(Header("Privacy notice"), aboveBar: false)
    }
}
