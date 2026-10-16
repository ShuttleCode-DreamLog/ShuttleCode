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

struct DreamDetailView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var model: DreamModel
    @State private var analysis: AnalysisModel
    @State private var editing = false
    @State private var showSwitches = false
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
        List {
            if let error = model.error ?? analysis.error {
                Section { Text(error).foregroundStyle(.red); Button("Try again") { Task { await load() } } }
            }
            if let dream = model.dream {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(dream.title ?? "Untitled dream").font(.title3.weight(.semibold))
                        Text("\(displayDate(dream.dreamDate)) · \(model.draft?.unsent == true ? "Saved on this device · Waiting to sync" : "Saved · Synced")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Your Dream") {
                    Text(dream.text).textSelection(.enabled)
                    if let mood = dream.mood { LabeledContent("Mood", value: mood.rawValue.capitalized) }
                }
                permissionsSection(dream)
                organizationSection(dream)
                analysisSection(dream)
                if let value = analysis.analysis { contextSection(value, dream: dream) }
                Section { Button("Delete Dream", role: .destructive) { confirmingDelete = true } }
            } else if model.isLoading { ProgressView("Loading dream…") }
        }
        .dreamPage()
        .navigationTitle("Dream Detail")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { Button("Edit Dream") { editing = true }.disabled(model.dream == nil || model.isSending) }
        .sheet(isPresented: $editing, onDismiss: { Task { await load() } }) {
            NavigationStack { DreamEditorView(id: id, presented: true) }
        }
        .task { await load() }
        .refreshable { await load() }
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

    @ViewBuilder private func permissionsSection(_ dream: Dream) -> some View {
        let keptOut = dreamSwitches.allSatisfy { !dream.permissions[keyPath: $0.path] }
        Section {
            Toggle("Keep out of AI processing", isOn: Binding(get: { keptOut && !showSwitches }, set: { on in
                if !on { showSwitches = true }
                else if dream.permissions.history { confirmingKeepOut = true }
                else { Task { await keepOut() } }
            }))
            DisclosureGroup("AI switches", isExpanded: $showSwitches) {
                ForEach(dreamSwitches, id: \.key) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle(item.title, isOn: Binding(get: { dream.permissions[keyPath: item.path] }, set: { on in
                            if item.key == "history" && !on { confirmingHistoryOff = true }
                            else { Task { await model.savePermissions(app, [item.key: on]) } }
                        }))
                        Text(item.line).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        } header: { Text("AI use") } footer: {
            Text("Reading, searching and editing never need AI permission. Turning AI use off keeps your writing and does not rerun earlier analyses.")
        }
        .disabled(model.isSending)
    }
    private func keepOut() async {
        showSwitches = false
        await model.savePermissions(app, Dictionary(uniqueKeysWithValues: dreamSwitches.map { ($0.key, false) }))
    }

    @ViewBuilder private func organizationSection(_ dream: Dream) -> some View {
        let organize = dream.tasks.first { $0.type == .organize }
        Section {
            if let organize, organize.inProgress { Label("Preparing the summary and tags…", systemImage: "hourglass").font(.callout) }
            if let organize, organize.status == .failed {
                Text(failureText(organize)).font(.callout)
                Button("Retry summary and tags") { Task { await model.retry(app, task: organize); await analysis.load(app) } }
            }
            if let organization = dream.organization {
                let editable = organization.status == .current
                Text(organization.status == .current ? "Status: Up to date" : "Status: Outdated after an edit. A new summary follows.")
                    .font(.caption).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Summary").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(organization.summary)
                    if organization.summaryCorrected { Text("Your correction").font(.caption).foregroundStyle(.secondary) }
                }
                if editable { Button("Correct summary") { correctionText = organization.summary; correcting = .summary } }
                ForEach(organization.tags.filter { !$0.removed }) { tag in
                    Menu {
                        Button("Show dreams with this tag", systemImage: "line.3.horizontal.decrease") { app.showJournal(tag: tag.text) }
                        if editable {
                            Button("Rename…", systemImage: "pencil") { correctionText = tag.text; correcting = .tag(tag) }
                            if tag.corrected { Button("Restore “\(tag.originalText)”", systemImage: "arrow.uturn.backward") { Task { await restore(tag) } } }
                            Button("Remove", systemImage: "minus.circle", role: .destructive) {
                                Task { await model.correct(app, DreamCorrection(category: tag.category.rawValue, originalText: tag.originalText, text: "")) }
                            }
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tag.text).foregroundStyle(.primary)
                            Text("\(tag.category.rawValue.capitalized)\(tag.feeling == .inferred ? " · inferred" : "")\(tag.corrected ? " · your correction" : "") · “\(tag.excerpt)”")
                                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                        }
                    }
                }
                let removed = organization.tags.filter(\.removed)
                if !removed.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Removed tags").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(removed) { tag in
                            HStack {
                                Text(tag.originalText).strikethrough().foregroundStyle(.secondary)
                                Spacer()
                                if editable { Button("Restore") { Task { await restore(tag) } }.buttonStyle(.borderless) }
                            }
                        }
                    }
                }
            } else if organize == nil {
                Text(dream.permissions.analysis ? "No summary yet." : "Analysis is off for this dream, so no summary or tags are made.")
                    .foregroundStyle(.secondary)
            }
        } header: { Text("AI summary and tags") }
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
    @ViewBuilder private func analysisSection(_ dream: Dream) -> some View {
        let task = analysis.task
        let organize = dream.tasks.first { $0.type == .organize }
        Section {
            if let task, task.inProgress {
                Label(task.type == .organize ? "Preparing the summary and tags first…" : task.type == .transcribe ? "Preparing the transcript first…" : "Preparing the analysis…", systemImage: "hourglass")
                    .font(.callout)
                Text("The result appears when you return to this screen or pull to refresh.").font(.caption).foregroundStyle(.secondary)
            } else if let task, task.status == .failed {
                Text(failureText(task)).font(.callout)
                Button("Retry") { Task { await analysis.retry(app) } }
            }
            if let value = analysis.analysis {
                Text(task?.inProgress == true || value.status != .current ? "Status: Outdated" : "Status: Up to date")
                    .font(.caption).foregroundStyle(.secondary)
                if value.sections.isEmpty {
                    Text("This analysis has no sections left, because a source it was written with was deleted or excluded.").foregroundStyle(.secondary)
                }
                ForEach(Array(value.sections.enumerated()), id: \.offset) { _, section in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(section.kind.heading).font(.subheadline.weight(.semibold))
                        Text(value.text(of: section))
                        Text("Sources: \(value.sources(of: section).joined(separator: ", "))").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if value.withheld > 0 { Text("\(value.withheld) part(s) were left out because their sources could not be checked.").font(.caption).foregroundStyle(.secondary) }
                Text("These are tentative reflections, not diagnoses or established facts.").font(.caption).foregroundStyle(.secondary)
            } else if !dream.permissions.analysis {
                Text("Analysis is off for this dream.").foregroundStyle(.secondary)
            } else if task?.inProgress != true {
                Text("No analysis yet.").foregroundStyle(.secondary)
            }
            if analysis.analysis != nil && !dream.permissions.analysis { Text("Analysis is off for this dream.").font(.caption).foregroundStyle(.secondary) }
            if dream.permissions.analysis && task?.inProgress != true {
                // A refresh while the summary waits for the daily limit would buy a weaker analysis; retry that first (wiki 4.6.7).
                if let organize, organize.limited {
                    Button("Retry summary and tags") { Task { await model.retry(app, task: organize); await analysis.load(app) } }
                } else {
                    Button("Update Analysis") { if analysis.analysis == nil { Task { await analysis.refresh(app) } } else { confirmingRefresh = true } }
                        .buttonStyle(.borderedProminent)
                }
            }
        } header: { Text("AI analysis") }
        .disabled(analysis.isSending)
    }

    @ViewBuilder private func contextSection(_ value: Analysis, dream: Dream) -> some View {
        Section {
            ForEach(value.context) { entry in
                switch (entry.available, entry.kind, entry.label) {
                case (true, .memory, _): NavigationLink(value: Route.note(entry.sourceId)) { contextRow(entry) }
                case (true, .dream, let label) where label != "DREAM": NavigationLink(value: Route.dream(entry.sourceId)) { contextRow(entry) }
                default: contextRow(entry)
                }
            }
            if value.removedSources > 0 { Text("\(value.removedSources) source(s) used for this analysis have since been deleted or excluded.").font(.caption) }
            if value.dreamDate != dream.dreamDate || value.mood != dream.mood {
                Text("Written for the date \(displayDate(value.dreamDate)) and the mood \(value.mood?.rawValue ?? "not specified").").font(.caption)
            }
        } header: { Text("Information used for this analysis") } footer: {
            Text("Inputs, not evidence. Only records you allow are used; life notes and earlier dreams also need “Use life notes and earlier dreams” in Settings.")
        }
    }
    private func contextRow(_ entry: ContextEntry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.name)
            if !entry.available { Text("Changed since this analysis was made").font(.caption).foregroundStyle(.secondary) }
            else if entry.label == "DESC" { Text("Shown above under AI summary and tags").font(.caption).foregroundStyle(.secondary) }
            if let cut = entry.cutTo { Text("Only its first \(cut) characters were sent.").font(.caption).foregroundStyle(.secondary) }
        }
    }
}
