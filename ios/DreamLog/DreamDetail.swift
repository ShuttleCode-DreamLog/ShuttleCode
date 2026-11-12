import SwiftUI
import Observation

nonisolated enum Route: Hashable { case dream(String), note(String), draft(String), conversation(String, title: String) }

extension View {
    func routeDestinations() -> some View {
        navigationDestination(for: Route.self) { route in
            switch route {
            case let .dream(id): DreamDetailView(id: id)
            case let .note(id): NoteEditorView(id: id)
            case let .draft(id): DreamEditorView(id: id)
            case let .conversation(id, title): DiscussionView(dreamId: id, title: title)
            }
        }
    }
}

@Observable
final class AnalysisModel {
    let dreamId: String
    var analysis: Analysis?
    var task: TaskInfo?
    var error: String?
    var isSending = false
    private var epoch: Int?
    private var changes = 0
    init(dreamId: String) { self.dreamId = dreamId }
    private func current(_ app: AppModel) -> Bool { epoch == app.journalEpoch && !app.deleting && app.noticeSeen }
    func load(_ app: AppModel) async {
        guard !isSending, app.noticeSeen, !app.deleting, let client = app.client else { return }
        epoch = app.journalEpoch
        let started = changes
        let result = await client.loadAnalysis(dreamId)
        // A read that started before the last change is dropped, so it cannot replace that change's result (wiki 4.4.6, rule 6).
        guard current(app), started == changes else { return }
        switch result {
        case let .success(value): analysis = value.analysis; task = value.task; error = nil
        case let .failure(failure): error = failure.message
        }
    }
    func refresh(_ app: AppModel) async {
        guard !isSending, let client = app.client else { return }
        if epoch == nil { epoch = app.journalEpoch }
        isSending = true; changes += 1
        defer { isSending = false }
        let result = await client.refreshAnalysis(dreamId, refreshID: newID())
        guard current(app) else { return }
        switch result {
        case let .success(value): task = value; error = nil
        case let .failure(failure): error = failure.code == "cap_reached" || failure.code == "ceiling_reached" ? failureText(failure.code, .analyze) : failure.message
        }
    }
    func choose(_ app: AppModel, memory: String, choice: String?) async {
        guard !isSending, let client = app.client else { return }
        if epoch == nil { epoch = app.journalEpoch }
        isSending = true; changes += 1
        defer { isSending = false }
        let result = await client.chooseAnalysisNote(dreamId, memoryID: memory, choice: choice)
        guard current(app) else { return }
        switch result {
        case let .success(value): analysis = value.analysis; task = value.task; error = nil
        case let .failure(failure): error = failure.message
        }
    }
    func retry(_ app: AppModel) async {
        guard !isSending, let failed = task, let client = app.client else { return }
        if epoch == nil { epoch = app.journalEpoch }
        isSending = true; changes += 1
        defer { isSending = false }
        let result = await client.retryTask(failed.id)
        guard current(app) else { return }
        switch result {
        case let .success(value): task = value; error = nil
        case let .failure(failure): error = failure.code == "cap_reached" || failure.code == "ceiling_reached" ? failureText(failure.code, failed.type) : failure.message
        }
    }
}


// The six switches (wiki 4.5.8); their explanatory lines are not shown, the privacy notice covers what each AI use sends.
let dreamSwitches: [(key: String, path: WritableKeyPath<Permissions, Bool>, title: String)] = [
    ("analysis", \.analysis, "Analysis"),
    ("history", \.history, "Use as history"),
    ("patterns", \.patterns, "Patterns and search"),
    ("transcription", \.transcription, "Transcription"),
    ("discussion", \.discussion, "Discussion"),
    ("visuals", \.visuals, "Visuals")
]
let historyOffLine = "Turning this off removes the parts of analyses that cite it and starts the discussions that used it afresh. Turning it on again does not bring them back."
let correctionLine = "A correction marks the analysis as outdated and starts the discussion afresh."

// The dream page's sections a user can reorder (Re-Design list, AI use); the date row stays first and AI use stays last.
nonisolated enum DreamSection: String, CaseIterable, Identifiable {
    case tags, originalText, summary, analysis
    var id: String { rawValue }
    var title: String { switch self { case .tags: "Tags"; case .originalText: "Original text"; case .summary: "Summary"; case .analysis: "Analysis" } }
}
let dreamSectionOrderKey = "dreamSectionOrder"
// A stored order drops names it does not know and appends sections it lacks, so adding a section later keeps a user's order.
nonisolated func dreamSections(_ stored: String) -> [DreamSection] {
    let known = stored.split(separator: ",").compactMap { DreamSection(rawValue: String($0)) }
    let unique = known.enumerated().filter { known.firstIndex(of: $0.element) == $0.offset }.map(\.element)
    return unique + DreamSection.allCases.filter { !unique.contains($0) }
}

// The prototype's dream page: date and Edit, the sections in the user's order, AI use, then Delete Dream. Edit and Delete sit as on
// a life note, and Edit opens the title and text together.
struct DreamDetailView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var model: DreamModel
    @State private var analysis: AnalysisModel
    @State private var editing = false
    @State private var showSwitches = false
    @State private var showingSources = false
    @State private var pickingNote = false
    @State private var arranging = false
    @State private var collapsed: Set<String> = []
    @AppStorage(dreamSectionOrderKey) private var sectionOrder = ""
    @State private var confirmingDelete = false
    @State private var confirmingKeepOut = false
    @State private var confirmingHistoryOff = false
    @State private var confirmingRefresh = false
    @State private var renaming: Tag?
    @State private var correctionText = ""
    let id: String

    init(id: String) {
        self.id = id
        _model = State(initialValue: DreamModel(id: id))
        _analysis = State(initialValue: AnalysisModel(dreamId: id))
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let error = model.error ?? analysis.error { ErrorCard(error) { Task { await load() } } }
                if let dream = model.dream {
                    HStack(alignment: .firstTextBaseline) {
                        Hint(displayDate(dream.dreamDate) + (model.draft?.unsent == true ? " · Waiting to sync" : ""))
                        Spacer()
                        Button("Edit", systemImage: "pencil") { editing = true }.buttonStyle(.secondary).disabled(model.isSending).accessibilityIdentifier("Edit Dream")
                    }
                    // Sources and the AI switches are kept off the prototype's page until asked for.
                    ForEach(dreamSections(sectionOrder)) { section in sectionBlock(section, dream: dream) }
                    Button("Arrange sections") { arranging = true }.buttonStyle(.quiet).padding(.top, 8).accessibilityIdentifier("arrangeSections")
                    foldHeading("AI use", key: "aiUse")
                    if !collapsed.contains("aiUse") { permissionsBlock(dream) }
                    Button("Delete Dream", role: .destructive) { confirmingDelete = true }.buttonStyle(.quiet).padding(.top, 8)
                } else if model.isLoading { ProgressView("Loading dream…") }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
        .dreamPage()
        .page(Header(model.dream?.title ?? "Dream", leading: { BackButton() }, trailing: { HomeButton() }))
        .sheet(isPresented: $editing, onDismiss: { Task { await load() } }) {
            NavigationStack { DreamEditorView(id: id, presented: true) }
        }
        // The sheet is its own presentation, so it carries the routes its note and dream links open.
        .sheet(isPresented: $showingSources, onDismiss: { Task { await load() } }) {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if let value = analysis.analysis, let dream = model.dream { contextBlock(value, dream: dream) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(24)
                }
                .dreamPage()
                .page(Header("Information used", leading: { BackButton(label: "Done") { showingSources = false } }, trailing: { EmptyView() }), aboveBar: false)
                .routeDestinations()
                .sheet(isPresented: $pickingNote) {
                    NavigationStack {
                        NotePickerView(excluded: listedNotes) { memory in Task { await analysis.choose(app, memory: memory, choice: "added") } }
                    }
                }
            }
        }
        .sheet(isPresented: $arranging) {
            NavigationStack {
                List {
                    ForEach(dreamSections(sectionOrder)) { Text($0.title) }
                        .onMove { from, to in
                            var order = dreamSections(sectionOrder)
                            order.move(fromOffsets: from, toOffset: to)
                            sectionOrder = order.map(\.rawValue).joined(separator: ",")
                        }
                    Button("Reset to default") { sectionOrder = "" }.disabled(sectionOrder.isEmpty)
                }
                .environment(\.editMode, .constant(.active))
                .dreamPage()
                .page(Header("Arrange sections", leading: { BackButton(label: "Done") { arranging = false } }, trailing: { EmptyView() }), aboveBar: false)
            }
            .presentationDetents([.medium])
        }
        .task { await load() }
        // While the summary and tags or the analysis are still being made on the server, the page waits and reads again, so the
        // result appears by itself (wiki 4.4.6, rule 3); the wait ends with the page or the work.
        .readsAgain(while: awaitingWork, client: app.client) { await load() }
        .reloadable { await load() }
        .onChange(of: app.refreshes) { Task { await load() } }
        .confirmationDialog("Delete this dream? Deleting this dream also removes the analyses of other dreams and the discussion replies that were written with it.", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete Dream", role: .destructive) { Task { await model.delete(app); if model.deleted { dismiss() } } }
        }
        .confirmationDialog("Keep this dream out of AI processing? \(historyOffLine)", isPresented: $confirmingKeepOut, titleVisibility: .visible) {
            Button("Keep out of AI processing", role: .destructive) { Task { await keepOut() } }
        }
        .confirmationDialog(historyOffLine, isPresented: $confirmingHistoryOff, titleVisibility: .visible) {
            Button("Turn off Use as history", role: .destructive) { Task { await model.savePermissions(app, ["history": false]) } }
        }
        .confirmationDialog("A new analysis replaces this one and starts this dream's discussion afresh.\(allowance)", isPresented: $confirmingRefresh, titleVisibility: .visible) {
            Button("Update Analysis") { Task { await analysis.refresh(app) } }
        }
        .alert(renaming.map { "Rename “\($0.text)”" } ?? "", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }), presenting: renaming) { tag in
            TextField("New wording", text: $correctionText)
            Button("Save") { Task { await rename(tag) } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in Text(correctionLine) }
    }

    private var awaitingWork: Bool {
        analysis.task?.inProgress == true || model.dream?.tasks.contains { $0.type == .organize && $0.inProgress } == true
    }
    private func load() async {
        // An open editor owns this dream's draft until it closes.
        guard !editing else { return }
        async let dream: Void = model.load(app)
        async let reading: Void = analysis.load(app)
        _ = await (dream, reading)
    }
    private var allowance: String {
        guard let text = app.me?.usage.first(where: { $0.kind == "text" }) else { return "" }
        return " About \(max(0, text.cap - text.used)) text generations are left today."
    }

    // Tags are pills; each opens its corrections, and a removed tag stays, struck through, until it is restored.
    @ViewBuilder private func tagsBlock(_ dream: Dream) -> some View {
        TagSelectionControl(selectedIDs: dream.customTags?.map(\.id) ?? [], initialTags: dream.customTags ?? []) { ids in
            await model.saveTags(app, ids: ids)
        }
    }

    @ViewBuilder private func sectionBlock(_ section: DreamSection, dream: Dream) -> some View {
        // Every section folds under its heading (Re-Design list, 6 November 2026); the tags get a heading so they can fold too.
        if section == .analysis {
            // Supporting life notes sit beside the analysis they informed (Re-Design list, Life notes 3).
            HStack(alignment: .firstTextBaseline) {
                foldHeading(section.title, key: section.rawValue)
                Spacer()
                if let value = analysis.analysis {
                    Button("Supporting life notes (\(value.context.count { $0.kind == .memory } + (value.pendingNotes?.count ?? 0))) ›") { showingSources = true }
                        .buttonStyle(.quiet).accessibilityIdentifier("analysisSources")
                }
            }
        } else {
            foldHeading(section.title, key: section.rawValue)
        }
        if !collapsed.contains(section.rawValue) { sectionContent(section, dream: dream) }
    }
    private func foldHeading(_ title: String, key: String) -> some View {
        let folded = collapsed.contains(key)
        return Button { withAnimation(.snappy) { collapsed.formSymmetricDifference([key]) } } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "chevron.down").font(.callout.weight(.semibold)).rotationEffect(.degrees(folded ? -90 : 0)).foregroundStyle(Color.muted)
                Heading(title)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(folded ? "Collapsed" : "Expanded")
        .accessibilityIdentifier("fold-\(key)")
    }
    @ViewBuilder private func sectionContent(_ section: DreamSection, dream: Dream) -> some View {
        switch section {
        case .tags: tagsBlock(dream)
        case .originalText:
            Text(dream.text).font(.callout).textSelection(.enabled)
            if let mood = dream.mood { Hint("Mood · \(mood.rawValue.capitalized)") }
        case .summary: organizationBlock(dream)
        case .analysis:
            analysisBlock(dream)
            // The discussion entry stays with the analysis it continues (wiki 4.6.6).
            if !dream.permissions.discussion { Hint("Discussion is off") }
            else if !dream.text.isEmpty {
                NavigationLink(value: Route.conversation(id, title: dream.title ?? "Dream")) {
                    Label("Conversation analysis", systemImage: "bubble.left.and.bubble.right")
                }.buttonStyle(.primary).padding(.top, 8)
            }
        }
    }

    private func permissionsBlock(_ dream: Dream) -> some View {
        let keptOut = dreamSwitches.allSatisfy { !dream.permissions[keyPath: $0.path] }
        return VStack(alignment: .leading, spacing: 4) {
            Toggle("Keep out of AI processing", isOn: Binding(get: { keptOut && !showSwitches }, set: { on in
                if !on { showSwitches = true }
                else if dream.permissions.history { confirmingKeepOut = true }
                else { Task { await keepOut() } }
            })).switchRow()
            DisclosureGroup("AI switches", isExpanded: $showSwitches) {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(dreamSwitches, id: \.key) { item in
                        Toggle(item.title, isOn: Binding(get: { dream.permissions[keyPath: item.path] }, set: { on in
                            if item.key == "history" && !on { confirmingHistoryOff = true }
                            else { Task { await model.savePermissions(app, [item.key: on]) } }
                        }))
                    }
                }.padding(.top, 8)
            }.padding(.vertical, 12)
        }
        .font(.callout)
        .disabled(model.isSending)
    }
    private func keepOut() async {
        showSwitches = false
        await model.savePermissions(app, Dictionary(uniqueKeysWithValues: dreamSwitches.map { ($0.key, false) }))
    }

    private func organizationBlock(_ dream: Dream) -> some View {
        let organize = dream.tasks.first { $0.type == .organize }
        return Group {
            if let organize, organize.inProgress { Label("Preparing the summary and tags…", systemImage: "hourglass").font(.callout) }
            if let organize, organize.status == .failed {
                Text(failureText(organize)).font(.callout)
                Button("Retry summary and tags") { Task { await model.retry(app, task: organize); await analysis.load(app) } }.buttonStyle(.secondary)
            }
            if let organization = dream.organization {
                if organization.status != .current { Hint("Outdated after an edit") }
                Text(organization.summary).font(.callout)
            } else if organize == nil {
                Hint(dream.permissions.analysis ? "No summary yet" : "Analysis is off")
            }
        }
        .disabled(model.isSending)
    }
    private func restore(_ tag: Tag) async {
        await model.correct(app, DreamCorrection(category: tag.category.rawValue, originalText: tag.originalText, text: tag.originalText))
    }
    private func rename(_ tag: Tag) async {
        let text = correctionText.trimmingCharacters(in: .whitespacesAndNewlines)
        await model.correct(app, DreamCorrection(category: tag.category.rawValue, originalText: tag.originalText, text: text))
    }

    // What the analysis presents follows the order of the wiki 4.6.7 table.
    private func analysisBlock(_ dream: Dream) -> some View {
        let task = analysis.task
        let organize = dream.tasks.first { $0.type == .organize }
        return Group {
            if let task, task.inProgress {
                Label(task.type == .organize ? "Preparing the summary and tags first…" : task.type == .transcribe ? "Preparing the transcript first…" : "Preparing the analysis…", systemImage: "hourglass")
                    .font(.callout)
            } else if let task, task.status == .failed {
                Text(failureText(task)).font(.callout)
                Button("Retry") { Task { await analysis.retry(app) } }.buttonStyle(.secondary)
            }
            if let value = analysis.analysis {
                if task?.inProgress == true || value.status != .current { Hint("Outdated") }
                if value.sections.isEmpty { Hint("Its sources were deleted or excluded") }
                ForEach(Array(value.sections.enumerated()), id: \.offset) { _, section in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(section.kind.heading).font(.callout.weight(.semibold))
                        // Symbols arrive as "- **Name:** …" lines; inline markdown renders the bold and keeps the line breaks.
                        Text((try? AttributedString(markdown: value.text(of: section), options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(value.text(of: section))).font(.callout)
                        Hint("Sources: \(value.sources(of: section).joined(separator: ", "))")
                    }.padding(.top, 4)
                }
                if value.withheld > 0 { Hint("\(value.withheld) part(s) left out") }
            } else if !dream.permissions.analysis {
                Hint("Analysis is off")
            } else if task?.inProgress != true {
                Hint("No analysis yet")
            }
            if analysis.analysis != nil && !dream.permissions.analysis { Hint("Analysis is off") }
            if dream.permissions.analysis && task?.inProgress != true {
                // A refresh while the summary waits for the daily limit would buy a weaker analysis; retry that first (wiki 4.6.7).
                if let organize, organize.limited {
                    Button("Retry summary and tags") { Task { await model.retry(app, task: organize); await analysis.load(app) } }.buttonStyle(.secondary)
                } else {
                    Button("Update Analysis") { if analysis.analysis == nil { Task { await analysis.refresh(app) } } else { confirmingRefresh = true } }
                        .buttonStyle(.primary)
                }
            }
        }
        .disabled(analysis.isSending)
    }

    private func contextBlock(_ value: Analysis, dream: Dream) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // The dream and its own summary and tags are always used, so the list shows only the notes and earlier dreams (Re-Design list, 6 November 2026).
            ForEach(value.context.filter { $0.label != "DREAM" && $0.kind != .output }) { entry in
                HStack {
                    switch (entry.available, entry.kind, entry.label) {
                    case (true, .memory, _): NavigationLink(value: Route.note(entry.sourceId)) { contextRow(entry, link: true) }.buttonStyle(.plain)
                    case (true, .dream, let label) where label != "DREAM": NavigationLink(value: Route.dream(entry.sourceId)) { contextRow(entry, link: true) }.buttonStyle(.plain)
                    default: contextRow(entry, link: false)
                    }
                    // Every note can be taken out, whether it was added or picked automatically; it leaves on the next Update Analysis (Re-Design list, 6 November 2026).
                    if entry.kind == .memory && entry.choice == "removed" {
                        Button("Undo") { choose(entry.sourceId, nil) }.buttonStyle(.quiet).disabled(analysis.isSending)
                    } else if entry.kind == .memory {
                        removeButton(entry.sourceId, name: entry.name)
                    }
                }
            }
            ForEach(value.pendingNotes ?? []) { pending in
                HStack {
                    NavigationLink(value: Route.note(pending.sourceId)) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) { Text(pending.name).font(.callout); Hint("Added · used after Update Analysis") }
                            Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(Color.muted)
                        }
                    }.buttonStyle(.plain)
                    removeButton(pending.sourceId, name: pending.name)
                }
            }
            if let error = analysis.error { Hint(error) }
            if app.me?.useHistory == true {
                Button("+ Add life note") { pickingNote = true }
                    .buttonStyle(.quiet).disabled(analysis.isSending || addedCount(value) >= 4).accessibilityIdentifier("addAnalysisNote")
            }
            if value.removedSources > 0 { Hint("\(value.removedSources) source(s) since deleted or excluded") }
            if value.dreamDate != dream.dreamDate || value.mood != dream.mood {
                Hint("Written for \(displayDate(value.dreamDate)) · \(value.mood?.rawValue.capitalized ?? "No mood")")
            }
        }.padding(.top, 8)
    }
    private func removeButton(_ memory: String, name: String) -> some View {
        Button { choose(memory, "removed") } label: { Image(systemName: "minus.circle").foregroundStyle(Color.muted) }
            .buttonStyle(.plain).disabled(analysis.isSending).accessibilityLabel("Remove \(name)")
    }
    private func choose(_ memory: String, _ choice: String?) { Task { await analysis.choose(app, memory: memory, choice: choice) } }
    private func addedCount(_ value: Analysis) -> Int { value.context.count { $0.choice == "added" } + (value.pendingNotes?.count ?? 0) }
    private var listedNotes: Set<String> {
        guard let value = analysis.analysis else { return [] }
        return Set(value.context.filter { $0.kind == .memory && $0.choice != "removed" }.map(\.sourceId) + (value.pendingNotes ?? []).map(\.sourceId))
    }
    private func contextRow(_ entry: ContextEntry, link: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name).font(.callout)
                if entry.choice == "removed" { Hint("Removed · leaves after Update Analysis") }
                if !entry.available { Hint("Changed since this analysis") }
                if let cut = entry.cutTo { Hint("First \(cut) characters") }
            }
            if link { Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(Color.muted) }
        }
    }
}
