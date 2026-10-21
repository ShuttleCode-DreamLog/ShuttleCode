import SwiftUI

struct HistoryToggle: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        Toggle("Use life notes and earlier dreams", isOn: Binding(get: { model.me?.useHistory ?? true }, set: { value in Task { await model.saveHistory(value) } }))
            .disabled(!model.settingsAvailable)
    }
}

// Settings is the last tab (DreamLog_User_Test.html nav).
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 13) {
                    PageHeading("Make space your way.", lede: "Choose what is available for reflection.")
                    HistoryToggle().font(.callout).switchRow()
                    Hint("Capture dreams and explore tentative reflections. This switch lets permitted life notes and earlier dreams be sent as context when a dream is analyzed. A dream or note you exclude stays excluded. Changes apply to future analyses and do not rerun earlier ones.")
                    if let error = model.error { ErrorCard(error, retryTitle: "Retry loading settings") { Task { await model.load() } } }
                    ProfileSettings()
                    Heading("Privacy")
                    PrivacyText()
                    Heading("Your journal")
                    DeleteJournalButton()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
            }
            .dreamPage()
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

struct DeleteJournalButton: View {
    @Environment(AppModel.self) private var model
    @State private var confirming = false
    var body: some View {
        Button("Delete my journal", role: .destructive) { confirming = true }
            .buttonStyle(.secondary)
            .disabled(model.isBusy)
            .confirmationDialog("Delete every journal record and file on the server and this phone? This cannot be undone.", isPresented: $confirming, titleVisibility: .visible) {
                Button("Delete my journal", role: .destructive) { Task { await model.deleteJournal() } }
            }
    }
}

struct DeletionView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmingErase = false
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                if model.deleteFailed {
                    Text(model.error ?? "Deletion could not finish.").font(.callout)
                    Button("Try again") { Task { await model.retryDeletion() } }.buttonStyle(.primary)
                    Button("Erase this phone only", role: .destructive) { confirmingErase = true }.buttonStyle(.secondary)
                    if model.canCancelDeletion { Button("Cancel") { Task { await model.cancelDeletion() } }.buttonStyle(.quiet) }
                } else { ProgressView("Deleting your journal…") }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(24)
            .dreamPage()
            .navigationTitle("Delete journal")
            .confirmationDialog("This erases everything on this phone. If the server journal still exists, you will no longer be able to open or delete it from this phone. It will be deleted when the course project ends.", isPresented: $confirmingErase, titleVisibility: .visible) {
                Button("Erase this phone only", role: .destructive) { Task { await model.erasePhone() } }
            }
        }
    }
}
