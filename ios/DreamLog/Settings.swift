import SwiftUI

// Settings sits at the top right of every tab root and opens over it (EGMUIUX S08).
struct SettingsButton: View {
    @State private var showing = false
    var body: some View {
        Button("Settings") { showing = true }.sheet(isPresented: $showing) { SettingsView() }
    }
}

struct HistoryToggle: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        Toggle("Use life notes and earlier dreams", isOn: Binding(get: { model.me?.useHistory ?? true }, set: { value in Task { await model.saveHistory(value) } }))
            .disabled(!model.settingsAvailable)
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section {
                    HistoryToggle()
                } header: { Text("Your journal, your choices") } footer: {
                    Text("Capture dreams and explore tentative reflections. This switch lets permitted life notes and earlier dreams be sent as context when a dream is analyzed. A dream or note you exclude stays excluded. Changes apply to future analyses and do not rerun earlier ones.")
                }
                ProfileSettings()
                if let error = model.error {
                    Section { Text(error).foregroundStyle(.red); Button("Retry loading settings") { Task { await model.load() } } }
                }
                PrivacyText()
                Section { DeleteJournalButton() }
            }
            .dreamPage()
            .navigationTitle("Settings")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

struct DeleteJournalButton: View {
    @Environment(AppModel.self) private var model
    @State private var confirming = false
    var body: some View {
        Button("Delete my journal", role: .destructive) { confirming = true }
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
            VStack(spacing: 20) {
                if model.deleteFailed {
                    Text(model.error ?? "Deletion could not finish.")
                    Button("Try again") {
                        Task { await model.retryDeletion() }
                    }
                    Button("Erase this phone only", role: .destructive) { confirmingErase = true }
                    if model.canCancelDeletion { Button("Cancel") { Task { await model.cancelDeletion() } } }
                } else { ProgressView("Deleting your journal…") }
            }
            .padding().navigationTitle("Delete journal")
            .confirmationDialog("This erases everything on this phone. If the server journal still exists, you will no longer be able to open or delete it from this phone. It will be deleted when the course project ends.", isPresented: $confirmingErase, titleVisibility: .visible) {
                Button("Erase this phone only", role: .destructive) { Task { await model.erasePhone() } }
            }
        }
    }
}
