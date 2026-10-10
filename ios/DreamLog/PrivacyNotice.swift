import SwiftUI
import CryptoKit

let noticeVersion = 3
let noticeKey = "notice-version"
let noticeContentKey = "notice-content-fingerprint"
let noticeIntroduction = "Development build: AI and recording are unavailable. Read how this project handles your data."
let deletionKey = "deletion-started"
let reminderKey = "reminder-weekday"
let answeredOffersKey = "answered-offers"

struct PrivacyPart: Identifiable {
    let title: String
    let text: String
    var id: String { title }
}

let privacyParts: [PrivacyPart] = [
    .init(title: "AI", text: "This build sends nothing to AI. Future features may send dream text, permitted life notes and earlier dreams, discussion messages, or audio for transcription. A new notice is required before they are enabled."),
    .init(title: "Deletion", text: "Deleting a record removes our stored copy, not data an AI provider may retain under its own policy. Provider retention terms must be confirmed before AI is enabled."),
    .init(title: "Storage", text: "Journals, notes and profile fields are stored on the project server; its operators can read them."),
    .init(title: "Permissions", text: "History is in Settings. Dream editors hold per-dream switches; notes have an AI context switch. Microphone permission will be managed in iOS Settings when recording is available."),
    .init(title: "Recordings", text: "Recording is unavailable. Planned server audio is deleted after a usable transcript is stored, transcription is turned off, or the dream is deleted. The phone keeps its copy until you see the transcript and its draft is sent, unless you discard/delete it. Failed transcription keeps audio; deleted audio cannot be replayed."),
    .init(title: "Project", text: "Delete my journal removes this device’s entire server journal, local data and identity. The project plan is to delete remaining server journals at course end; the date and cleanup must be confirmed before public release.")
]

// Content changes require consent even when a version bump is accidentally omitted.
let noticeFingerprint = SHA256.hash(data: Data(([noticeIntroduction] + privacyParts.flatMap { [$0.title, $0.text] }).joined(separator: "\u{0}").utf8))
    .map { String(format: "%02x", $0) }.joined()

struct PrivacyText: View {
    var body: some View {
        ForEach(privacyParts) { part in
            Section(part.title) { Text(part.text) }
        }
    }
}

struct PrivacyNoticeView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        NavigationStack {
            List {
                Section { Text(noticeIntroduction) }
                PrivacyText()
                Section { Button("I acknowledge this notice") { Task { await model.acknowledgeNotice() } } }
                if model.hasPriorAcknowledgment { Section { DeleteJournalButton() } }
            }
            .navigationTitle("Privacy notice")
        }
    }
}
