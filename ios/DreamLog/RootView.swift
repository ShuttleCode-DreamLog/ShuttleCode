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
                VStack(alignment: .leading, spacing: 16) {
                    if let error = model.error {
                        Text(error).font(.callout)
                        Button("Try again") { Task { await model.start() } }.buttonStyle(.secondary)
                    } else { ProgressView("Opening DreamLog…") }
                }
                .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity).dreamPage()
            } else if !model.noticeSeen { PrivacyNoticeView() }
            else {
                // The prototype's shell: one screen at a time above its own bottom bar; Home shows at launch and after ⌂.
                Group {
                    if model.showingHome { HomeView() }
                    else {
                        switch model.tab {
                        case .journal: JournalView()
                        case .patterns: PatternsView()
                        case .notes: NotesView()
                        case .settings: SettingsView()
                        }
                    }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) { BottomBar() }
                .sheet(item: $model.newDream, onDismiss: { model.refreshes += 1 }) { entry in
                    NavigationStack { DreamEditorView(id: entry.id, newEntry: true) }
                }
            }
        }
        .tint(.sage)
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
