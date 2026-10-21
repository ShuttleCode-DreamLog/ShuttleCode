import SwiftUI
import Observation

nonisolated enum Route: Hashable { case dream(String), note(String), draft(String) }

extension View {
    func routeDestinations() -> some View {
        navigationDestination(for: Route.self) { route in
            switch route {
            case let .dream(id): DreamDetailView(id: id)
            case let .note(id): NoteEditorView(id: id)
            case let .draft(id): DreamEditorView(id: id)
            }
        }
    }
}

@MainActor @Observable
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

nonisolated enum CorrectionTarget: Identifiable {
    case summary, tag(Tag)
    var id: String { if case let .tag(tag) = self { tag.id } else { "summary" } }
}

// The six switches with their fixed lines (wiki 4.5.8).
let dreamSwitches: [(key: String, path: WritableKeyPath<Permissions, Bool>, title: String, line: String)] = [
    ("analysis", \.analysis, "Analysis", "Sends this dream's text, date, and mood to the AI service for a summary, tags, and an analysis. When it is off, none of the three is made and the dream takes no part in pattern findings."),
    ("history", \.history, "Use as history", "Lets this dream's text be sent as an earlier dream when another dream is analyzed or discussed. This is separate from the analysis switch: with history on, the text can be sent even when this dream's own analysis is off."),
    ("patterns", \.patterns, "Patterns and search", "Sends this dream's text to the AI service so that it can be found by meaning and compared with other dreams."),
    ("transcription", \.transcription, "Transcription", "Sends this dream's recording to the AI service to turn it into text."),
    ("discussion", \.discussion, "Discussion", "Sends this dream and your messages about it to the AI service for replies, together with its summary, tags, and analysis where they exist, also when the analysis switch is off."),
    ("visuals", \.visuals, "Visuals", "Sends a scene of this dream to the AI service to make a picture or a video.")
]
let historyOffLine = "Turning this off removes the parts of analyses that cite it and starts the discussions that used it afresh. Turning it on again does not bring them back."
let correctionLine = "A correction marks the analysis as outdated and starts the discussion afresh."

// The prototype's dream page: date and Delete, tags, Original text, Summary, Analysis; the sources and AI switches follow below.
struct DreamDetailView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var model: DreamModel
    @State private var analysis: AnalysisModel
    @State private var editing = false
    @State private var showSwitches = false
    @State private var showContext = false
    @State private var confirmingDelete = false
    @State private var confirmingKeepOut = false
    @State private var confirmingHistoryOff = false
    @State private var confirmingRefresh = false
    @State private var correcting: CorrectionTarget?
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
                        Hint("\(displayDate(dream.dreamDate)) · \(model.draft?.unsent == true ? "Saved on this device · Waiting to sync" : "Synced")")
                        Spacer()
                        Button("Delete Dream", role: .destructive) { confirmingDelete = true }.buttonStyle(.quiet)
                    }
                    tagsBlock(dream)
                    Heading("Original text")
                    Text(dream.text).font(.callout).textSelection(.enabled)
                    if let mood = dream.mood { Hint("Mood · \(mood.rawValue.capitalized)") }
                    Button("Edit text") { editing = true }.buttonStyle(.secondary).disabled(model.isSending).accessibilityIdentifier("Edit Dream")
                    Heading("Summary")
                    organizationBlock(dream)
                    Heading("Analysis")
                    analysisBlock(dream)
                    if let value = analysis.analysis {
                        DisclosureGroup("Information used for this analysis", isExpanded: $showContext) { contextBlock(value, dream: dream) }.font(.callout).padding(.top, 8)
                    }
                    Heading("AI use")
                    permissionsBlock(dream)
                } else if model.isLoading { ProgressView("Loading dream…") }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
        .dreamPage()
        .navigationTitle(model.dream?.title ?? "Dream")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $editing, onDismiss: { Task { await load() } }) {
            NavigationStack { DreamEditorView(id: id, presented: true) }
        }
        .task { await load() }
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
        .alert(correctionTitle, isPresented: Binding(get: { correcting != nil }, set: { if !$0 { correcting = nil } }), presenting: correcting) { target in
            TextField("New wording", text: $correctionText)
            Button("Save") { Task { await saveCorrection(target) } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in Text(correctionLine) }
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
    private var correctionTitle: String {
        if case let .tag(tag) = correcting { "Rename “\(tag.text)”" } else { "Correct the summary" }
    }

    // Tags are pills; each opens its corrections, and a removed tag stays, struck through, until it is restored.
    @ViewBuilder private func tagsBlock(_ dream: Dream) -> some View {
        if let organization = dream.organization {
            let editable = organization.status == .current
            Wrap(spacing: 6) {
                ForEach(organization.tags.filter { !$0.removed }) { tag in
                    Menu {
                        Section("\(tag.category.rawValue.capitalized)\(tag.feeling == .inferred ? " · inferred" : "")\(tag.corrected ? " · your correction" : "") · “\(tag.excerpt)”") {
                            Button("Show dreams with this tag", systemImage: "line.3.horizontal.decrease") { app.showJournal(tag: tag.text) }
                            if editable {
                                Button("Rename…", systemImage: "pencil") { correctionText = tag.text; correcting = .tag(tag) }
                                if tag.corrected { Button("Restore “\(tag.originalText)”", systemImage: "arrow.uturn.backward") { Task { await restore(tag) } } }
                                Button("Remove", systemImage: "minus.circle", role: .destructive) {
                                    Task { await model.correct(app, DreamCorrection(category: tag.category.rawValue, originalText: tag.originalText, text: "")) }
                                }
                            }
                        }
                    } label: { Pill(tag.text) }
                }
                ForEach(organization.tags.filter(\.removed)) { tag in
                    Menu {
                        if editable { Button("Restore", systemImage: "arrow.uturn.backward") { Task { await restore(tag) } } }
                    } label: { Pill(tag.originalText, struck: true) }
                    .accessibilityLabel("Removed tag \(tag.originalText)")
                }
            }
            .disabled(model.isSending)
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
                        VStack(alignment: .leading, spacing: 4) {
                            Toggle(item.title, isOn: Binding(get: { dream.permissions[keyPath: item.path] }, set: { on in
                                if item.key == "history" && !on { confirmingHistoryOff = true }
                                else { Task { await model.savePermissions(app, [item.key: on]) } }
                            }))
                            Hint(item.line)
                        }
                    }
                }.padding(.top, 8)
            }.padding(.vertical, 12)
            Hint("Reading, searching and editing never need AI permission. Turning AI use off keeps your writing and does not rerun earlier analyses.")
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
                Hint(organization.status == .current ? "Up to date" : "Outdated after an edit. A new summary follows.")
                Text(organization.summary).font(.callout)
                if organization.summaryCorrected { Hint("Your correction") }
                if organization.status == .current {
                    Button("Correct summary") { correctionText = organization.summary; correcting = .summary }.buttonStyle(.quiet)
                }
            } else if organize == nil {
                Hint(dream.permissions.analysis ? "No summary yet." : "Analysis is off for this dream, so no summary or tags are made.")
            }
        }
        .disabled(model.isSending)
    }
    private func restore(_ tag: Tag) async {
        await model.correct(app, DreamCorrection(category: tag.category.rawValue, originalText: tag.originalText, text: tag.originalText))
    }
    private func saveCorrection(_ target: CorrectionTarget) async {
        let text = correctionText.trimmingCharacters(in: .whitespacesAndNewlines)
        switch target {
        case .summary: if !text.isEmpty { await model.correct(app, DreamCorrection(category: "summary", text: text)) }
        case let .tag(tag): await model.correct(app, DreamCorrection(category: tag.category.rawValue, originalText: tag.originalText, text: text))
        }
    }

    // What the analysis presents follows the order of the wiki 4.6.7 table.
    private func analysisBlock(_ dream: Dream) -> some View {
        let task = analysis.task
        let organize = dream.tasks.first { $0.type == .organize }
        return Group {
            if let task, task.inProgress {
                Label(task.type == .organize ? "Preparing the summary and tags first…" : task.type == .transcribe ? "Preparing the transcript first…" : "Preparing the analysis…", systemImage: "hourglass")
                    .font(.callout)
                Hint("The result appears when you return to this screen or pull to refresh.")
            } else if let task, task.status == .failed {
                Text(failureText(task)).font(.callout)
                Button("Retry") { Task { await analysis.retry(app) } }.buttonStyle(.secondary)
            }
            if let value = analysis.analysis {
                Hint(task?.inProgress == true || value.status != .current ? "Outdated" : "Up to date")
                if value.sections.isEmpty {
                    Hint("This analysis has no sections left, because a source it was written with was deleted or excluded.")
                }
                ForEach(Array(value.sections.enumerated()), id: \.offset) { _, section in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(section.kind.heading).font(.callout.weight(.semibold))
                        Text(value.text(of: section)).font(.callout)
                        Hint("Sources: \(value.sources(of: section).joined(separator: ", "))")
                    }.padding(.top, 4)
                }
                if value.withheld > 0 { Hint("\(value.withheld) part(s) were left out because their sources could not be checked.") }
                Hint("These are tentative reflections, not diagnoses or established facts.")
            } else if !dream.permissions.analysis {
                Hint("Analysis is off for this dream.")
            } else if task?.inProgress != true {
                Hint("No analysis yet.")
            }
            if analysis.analysis != nil && !dream.permissions.analysis { Hint("Analysis is off for this dream.") }
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
            ForEach(value.context) { entry in
                switch (entry.available, entry.kind, entry.label) {
                case (true, .memory, _): NavigationLink(value: Route.note(entry.sourceId)) { contextRow(entry, link: true) }.buttonStyle(.plain)
                case (true, .dream, let label) where label != "DREAM": NavigationLink(value: Route.dream(entry.sourceId)) { contextRow(entry, link: true) }.buttonStyle(.plain)
                default: contextRow(entry, link: false)
                }
            }
            if value.removedSources > 0 { Hint("\(value.removedSources) source(s) used for this analysis have since been deleted or excluded.") }
            if value.dreamDate != dream.dreamDate || value.mood != dream.mood {
                Hint("Written for the date \(displayDate(value.dreamDate)) and the mood \(value.mood?.rawValue ?? "not specified").")
            }
            Hint("Inputs, not evidence. Only records you allow are used; life notes and earlier dreams also need “Use life notes and earlier dreams” in Settings.")
        }.padding(.top, 8)
    }
    private func contextRow(_ entry: ContextEntry, link: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name).font(.callout)
                if !entry.available { Hint("Changed since this analysis was made") }
                else if entry.label == "DESC" { Hint("Shown above under Summary") }
                if let cut = entry.cutTo { Hint("Only its first \(cut) characters were sent.") }
            }
            if link { Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(Color.muted) }
        }
    }
}
