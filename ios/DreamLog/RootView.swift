import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        Group {
            if model.deleting { DeletionView() }
            else if !model.ready {
                VStack(spacing: 16) {
                    if let error = model.error { Text(error); Button("Try again") { Task { await model.start() } } }
                    else { ProgressView("Opening DreamLog…") }
                }.padding()
            } else if !model.noticeSeen { PrivacyNoticeView() }
            else {
                TabView {
                    Tab("Journal", systemImage: "book") { JournalView() }
                    Tab("Notes", systemImage: "note.text") { NotesView() }
                    Tab("Settings", systemImage: "gear") { SettingsView() }
                }
            }
        }
        .task { await model.start() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { if model.ready { await model.load() } else { await model.start() } } }
        }
    }
}
