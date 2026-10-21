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
                // The center tab opens the dream editor over the tabs instead of showing a screen of its own (DreamLog_User_Test.html nav).
                TabView(selection: Binding(get: { model.tab }, set: { tab in
                    if tab == .add { model.tab = .journal; model.newDream = EntryRoute(id: newID()) } else { model.tab = tab }
                })) {
                    Tab("Journal", systemImage: "list.bullet.rectangle", value: AppTab.journal) { JournalView() }
                    Tab("Pattern", systemImage: "lightbulb", value: AppTab.patterns) { PatternsView() }
                    Tab("Add dream", systemImage: "plus", value: AppTab.add) { Color.paper }
                    Tab("Life notes", systemImage: "pencil", value: AppTab.notes) { NotesView() }
                    Tab("Settings", systemImage: "gearshape", value: AppTab.settings) { SettingsView() }
                }
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
