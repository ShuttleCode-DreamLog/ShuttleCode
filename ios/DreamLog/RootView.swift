import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var wasBackground = false
    var body: some View {
        @Bindable var model = model
        Group {
            if model.deleting { DeletionView() }
            else if !model.ready {
                VStack(spacing: 16) {
                    if let error = model.error { Text(error); Button("Try again") { Task { await model.start() } } }
                    else { ProgressView("Opening DreamLog…") }
                }.padding()
            } else if !model.noticeSeen { PrivacyNoticeView() }
            else {
                TabView(selection: $model.tab) {
                    Tab("Journal", systemImage: "book", value: AppTab.journal) { JournalView() }
                    Tab("Patterns", systemImage: "leaf", value: AppTab.patterns) { PatternsView() }
                    Tab("Life Notes", systemImage: "note.text", value: AppTab.notes) { NotesView() }
                }
            }
        }
        .tint(.dusk)
        .task { await model.start() }
        .task { await model.watchConnection() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { wasBackground = true }
            if phase == .active {
                if wasBackground && model.ready { model.refreshes += 1 }
                wasBackground = false
                Task { if model.ready { await model.load() } else { await model.start() } }
            }
        }
    }
}
