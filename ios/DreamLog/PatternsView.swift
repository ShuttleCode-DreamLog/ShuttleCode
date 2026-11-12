import SwiftUI
import Observation

@Observable
final class PatternsModel {
    var response: PatternsResponse?
    var error: String?
    var isLoading = false
    var isSending = false
    private var changes = 0
    func load(_ app: AppModel) async {
        guard app.noticeSeen, !app.deleting, !isLoading, !isSending, let client = app.client else { return }
        isLoading = true
        defer { isLoading = false }
        let epoch = app.journalEpoch, started = changes
        let result = await client.loadPatterns()
        guard epoch == app.journalEpoch, !app.deleting, started == changes else { return }
        switch result {
        case let .success(value): response = value; error = nil
        case let .failure(failure): error = failure.message
        }
    }
    // Renaming, dismissing and splitting each return the whole patterns response, which replaces what is shown (wiki 4.8.10).
    @discardableResult
    private func change(_ app: AppModel, split: Bool = false, _ request: (APIClient) async -> Result<PatternsResponse, APIError>) async -> Bool {
        guard !isSending, app.noticeSeen, !app.deleting, let client = app.client else { return false }
        isSending = true; changes += 1
        let epoch = app.journalEpoch
        let result = await request(client)
        isSending = false
        guard epoch == app.journalEpoch, !app.deleting else { return false }
        switch result {
        case let .success(value): response = value; error = nil; return true
        case let .failure(failure):
            // A repeated split answers 409; the screen then reads the findings again and still says why.
            if split && failure.status == 409 { await load(app) }
            error = failure.message
            return false
        }
    }
    func rename(_ app: AppModel, _ finding: Finding, label: String) async {
        await change(app) { await $0.labelPattern(finding.groupId, PatternLabel(label: label)) }
    }
    // Dismiss deletes the whole pattern; its dreams stay in the journal.
    func dismiss(_ app: AppModel, _ finding: Finding) async -> Bool {
        await change(app) { await $0.deletePattern(finding.groupId) }
    }
    func removeDream(_ app: AppModel, _ finding: Finding, dreamId: String) async -> Bool {
        await change(app) { await $0.removePatternDream(finding.groupId, PatternDream(dreamId: dreamId)) }
    }
    func create(_ app: AppModel, label: String, dreamIds: [String]) async -> Bool {
        await change(app) { await $0.createPattern(PatternCreation(label: label, dreamIds: dreamIds)) }
    }
    func addDream(_ app: AppModel, _ finding: Finding, dreamId: String) async {
        await change(app) { await $0.addPatternDream(finding.groupId, PatternDream(dreamId: dreamId)) }
    }
    @discardableResult
    func split(_ app: AppModel, _ finding: Finding, dreamIds: [String], label: String) async -> Bool {
        await change(app, split: true) { await $0.splitPattern(finding.groupId, PatternSplit(dreamIds: dreamIds, label: label.isEmpty ? nil : label)) }
    }
    func retry(_ app: AppModel) async {
        guard !isSending, let task = response?.task, let client = app.client else { return }
        isSending = true
        defer { isSending = false }
        switch await client.retryTask(task.id) {
        case let .success(value): response?.task = value; error = nil
        case let .failure(failure): error = failure.message
        }
    }
}

extension APIError {
    var status: Int? { if case let .server(status, _, _) = self { status } else { nil } }
}

nonisolated struct PatternRoute: Hashable { let groupId: String }

// The prototype's patterns list: a search field and one card per finding that opens the pattern's own page.
struct PatternsView: View {
    @Environment(AppModel.self) private var app
    @State private var model = PatternsModel()
    @State private var path = NavigationPath()
    @State private var garden = true
    @State private var selected: String?
    @State private var query = ""
    var body: some View {
        @Bindable var app = app
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 13) {
                    Picker("View", selection: $garden) {
                        Text("Garden").tag(true)
                        Text("List").tag(false)
                    }.pickerStyle(.segmented)
                    if let error = model.error { ErrorCard(error) { Task { await model.load(app) } } }
                    if let response = model.response {
                        if !response.available {
                            Text("New matching is not available on the server at the moment. Patterns found earlier are still shown.").font(.callout).card()
                        }
                        if let task = response.task, task.status == .failed {
                            ErrorCard("The findings could not be updated. \(failureText(task))", retryTitle: "Retry") { Task { await model.retry(app) } }
                        }
                        if response.insufficientHistory {
                            EmptyCard("Not enough recorded history yet")
                        } else if garden {
                            gardenBlock(response)
                        } else {
                            TextField("Search patterns…", text: $query).field()
                            ForEach(response.findings.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }) { finding in
                                NavigationLink(value: PatternRoute(groupId: finding.groupId)) { FindingCard(finding: finding) }
                                    .buttonStyle(.plain).accessibilityIdentifier("patternCard")
                            }
                        }
                    } else if model.isLoading { ProgressView("Looking for patterns…") }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
            }
            .dreamPage()
            .page(Header("Patterns") { HomeButton() })
            .routeDestinations()
            .navigationDestination(for: PatternRoute.self) { route in PatternDetailView(groupId: route.groupId, model: model) }
            .disabled(model.isSending)
            .reloadable { await model.load(app) }
            .task { await model.load(app) }
            .onChange(of: path) { _, value in if value.isEmpty { Task { await model.load(app) } } }
            .onChange(of: app.refreshes) { Task { await model.load(app) } }
        }
        // On the stack, not its root page, so the bar's + also works while a pattern is open.
        .sheet(isPresented: $app.newPattern, onDismiss: { Task { await model.load(app) } }) {
            NavigationStack { NewPatternView(model: model) }
        }
    }
    // Garden: the same findings as plants sized by the number of distinct dreams that contain them (EGMUIUX S10).
    @ViewBuilder private func gardenBlock(_ response: PatternsResponse) -> some View {
        let current = response.findings.first { $0.groupId == selected } ?? response.findings.first
        BubbleCluster(bubbles: response.findings.map { Bubble(id: $0.groupId, label: $0.name, weight: Double($0.supportingDreams)) },
                      selected: current?.groupId) { selected = $0 }
            .padding(.vertical, 8)
        // The tapped bubble shows its pattern as the List's card; the dreams are on the pattern's own page.
        if let current {
            NavigationLink(value: PatternRoute(groupId: current.groupId)) { FindingCard(finding: current) }
                .buttonStyle(.plain).accessibilityIdentifier("patternCard")
        }
    }
}

struct FindingCard: View {
    let finding: Finding
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Eyebrow(finding.kind == .recurring ? "Recurring theme" : "Related examples")
            Text(finding.name).font(.heading)
            Hint("\(finding.supportingDreams) supporting dreams")
            ForEach(finding.dreams.prefix(3)) { Text("· \($0.name)").font(.callout) }
            if finding.status == .refreshing { Label("The explanation is being updated.", systemImage: "hourglass").font(.caption) }
        }
        .multilineTextAlignment(.leading)
        .card()
    }
}

// A supporting dream as the prototype's dream card: date, title, what it shares, and the excerpt in place of the summary.
struct ExampleCard: View {
    let example: FindingExample
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                Hint(shortDate(example.dreamDate))
                Text(example.name).font(.heading)
                Wrap(spacing: 4) {
                    Pill(example.description)
                    if let shared = example.sharedElement { Pill(shared) }
                }
                Text("“\(example.excerpt)”").font(.callout).foregroundStyle(Color.muted)
                if let difference = example.difference { Hint("Different: \(difference)") }
            }
            Spacer(minLength: 0)
            Text(glyph(nil)).font(.glyph).foregroundStyle(Color.motif)
        }
        .multilineTextAlignment(.leading)
        .card()
    }
}

// The prototype's pattern page: Rename, Supporting dreams, Summary & analysis; split and dismiss stay under Correct this pattern.
// Rename, Split and Dismiss sit at the top, then Summary & analysis, then the supporting dreams with their editor (Pattern page, 10 November 2026).
struct PatternDetailView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let groupId: String
    let model: PatternsModel
    @State private var renaming = false
    @State private var name = ""
    @State private var splitting = false
    @State private var dismissing = false
    @State private var editingDreams = false
    private var finding: Finding? { model.response?.findings.first { $0.groupId == groupId } }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let error = model.error { ErrorCard(error) }
                if let finding {
                    HStack(spacing: 8) {
                        Button("Rename") { name = finding.label ?? ""; renaming = true }.buttonStyle(.secondary)
                        Button("Split") { splitting = true }.buttonStyle(.secondary).disabled(finding.supportingDreams < 2)
                        Button("Dismiss") { dismissing = true }.buttonStyle(.secondary)
                    }
                    Heading("Summary & analysis")
                    if finding.status == .refreshing { Label("The explanation is being updated.", systemImage: "hourglass").font(.callout) }
                    else if let explanation = finding.explanation { Text(explanation).font(.callout) }
                    else { Hint("No explanation yet") }
                    HStack(alignment: .firstTextBaseline) {
                        Heading("Supporting dreams")
                        Spacer()
                        Button("Edit (\(finding.supportingDreams)) ›") { editingDreams = true }.buttonStyle(.quiet).accessibilityIdentifier("editSupportingDreams")
                    }
                    ForEach(finding.dreams) { example in
                        NavigationLink(value: Route.dream(example.dreamId)) { ExampleCard(example: example) }.buttonStyle(.plain)
                    }
                } else if model.response != nil {
                    EmptyCard("This pattern is no longer among the findings")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
        .dreamPage()
        .page(Header(finding?.name ?? "Pattern", leading: { BackButton() }, trailing: { HomeButton() }))
        .disabled(model.isSending)
        .alert("Rename pattern", isPresented: $renaming) {
            TextField("Pattern name", text: $name)
            Button("Save") { rename() }
            if finding?.labelCorrected == true { Button("Use generated name") { if let finding { Task { await model.rename(app, finding, label: "") } } } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Corrections change the pattern, not your dream text.") }
        .confirmationDialog("Dismiss “\(finding?.name ?? "this pattern")”? The pattern is deleted; its dreams stay in your journal.", isPresented: $dismissing, titleVisibility: .visible) {
            Button("Dismiss pattern", role: .destructive) {
                guard let finding else { return }
                Task { if await model.dismiss(app, finding) { dismiss() } }
            }
        }
        .sheet(isPresented: $splitting) {
            if let finding { NavigationStack { PatternSplitSheet(finding: finding, model: model) }.presentationDetents([.medium, .large]) }
        }
        // The sheet is its own presentation, so it carries the routes its dream links open.
        .sheet(isPresented: $editingDreams) {
            NavigationStack { SupportingDreamsSheet(groupId: groupId, model: model) }
        }
    }
    private func rename() {
        guard let finding else { return }
        let label = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty, label.count <= app.limits.maxLabelChars else { model.error = "Give the pattern a name of 1 to \(app.limits.maxLabelChars) characters."; return }
        Task { await model.rename(app, finding, label: label) }
    }
}

struct PatternSplitSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let finding: Finding
    let model: PatternsModel
    @State private var moving: Set<String> = []
    @State private var newName = ""
    @State private var confirming = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Eyebrow("Dreams for the new pattern")
                ForEach(finding.dreams) { example in
                    Toggle(example.name, isOn: Binding(get: { moving.contains(example.dreamId) }, set: { if $0 { moving.insert(example.dreamId) } else { moving.remove(example.dreamId) } }))
                }
                TextField("Name of the new pattern (optional)", text: $newName).field()
                Hint(preview)
                if let error = model.error { Hint(error) }
                Button("Save Split") { confirming = true }.buttonStyle(.primary)
                    .disabled(moving.isEmpty || moving.count >= finding.supportingDreams || model.isSending)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
        .dreamPage()
        .page(Header("Split pattern", leading: { BackButton(label: "Cancel") { dismiss() } }, trailing: { EmptyView() }), aboveBar: false)
        .confirmationDialog("The dreams you move will not be grouped with the others again, in either direction.", isPresented: $confirming, titleVisibility: .visible) {
            Button("Save Split") {
                Task { if await model.split(app, finding, dreamIds: Array(moving), label: newName.trimmingCharacters(in: .whitespacesAndNewlines)) { dismiss() } }
            }
        }
    }
    private var preview: String {
        let remaining = finding.supportingDreams - moving.count
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        return "“\(finding.name)” keeps \(remaining) dream\(remaining == 1 ? "" : "s") · “\(name.isEmpty ? "New pattern" : name)” gets \(moving.count) dream\(moving.count == 1 ? "" : "s")"
    }
}

// Like an analysis's Supporting life notes: each dream can be taken out, with Undo while the sheet is open, and + Add dream picks from the journal.
struct SupportingDreamsSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let groupId: String
    let model: PatternsModel
    @State private var removed: [FindingExample] = []
    @State private var picking = false
    private var finding: Finding? { model.response?.findings.first { $0.groupId == groupId } }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let finding {
                    let members = Set(finding.dreams.map(\.dreamId))
                    ForEach(finding.dreams) { example in
                        HStack {
                            NavigationLink(value: Route.dream(example.dreamId)) { row(example, hint: shortDate(example.dreamDate)) }.buttonStyle(.plain)
                            // A pattern needs two dreams; below that the whole pattern is dismissed instead.
                            Button { remove(finding, example) } label: { Image(systemName: "minus.circle").foregroundStyle(Color.muted) }
                                .buttonStyle(.plain).disabled(model.isSending || finding.supportingDreams <= 2).accessibilityLabel("Remove \(example.name)")
                        }
                    }
                    ForEach(removed.filter { !members.contains($0.dreamId) }) { example in
                        HStack {
                            row(example, hint: "Removed")
                            Button("Undo") { Task { await model.addDream(app, finding, dreamId: example.dreamId) } }.buttonStyle(.quiet).disabled(model.isSending)
                        }
                    }
                    if let error = model.error { Hint(error) }
                    Button("+ Add dream") { picking = true }.buttonStyle(.quiet).disabled(model.isSending).accessibilityIdentifier("addPatternDream")
                } else {
                    EmptyCard("This pattern is no longer among the findings")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
        .dreamPage()
        .page(Header("Supporting dreams", leading: { BackButton(label: "Done") { dismiss() } }, trailing: { EmptyView() }), aboveBar: false)
        .routeDestinations()
        .sheet(isPresented: $picking) {
            NavigationStack {
                DreamPickerView(excluded: Set(finding?.dreams.map(\.dreamId) ?? [])) { item in
                    if let finding { Task { await model.addDream(app, finding, dreamId: item.id) } }
                }
            }
        }
    }
    private func row(_ example: FindingExample, hint: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) { Text(example.name).font(.callout); Hint(hint) }
            Spacer()
        }
    }
    private func remove(_ finding: Finding, _ example: FindingExample) {
        Task { if await model.removeDream(app, finding, dreamId: example.dreamId) { removed.append(example) } }
    }
}

struct DreamPickerView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let excluded: Set<String>
    let pick: (JournalItem) -> Void
    @State private var model = JournalModel()
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 13) {
                if let error = model.error { ErrorCard(error) { Task { await model.load(app) } } }
                let dreams = model.items.filter { !excluded.contains($0.id) }
                if dreams.isEmpty && !model.isLoading { EmptyCard("No other dreams to add") }
                ForEach(dreams) { item in Button { pick(item); dismiss() } label: { DreamCard(row: JournalRow(id: item.id, item: item)) }.buttonStyle(.plain) }
                if model.hasMore {
                    Button("Load more") { Task { await model.load(app, more: true) } }.buttonStyle(.secondary).disabled(model.isLoading)
                }
                if model.isLoading { ProgressView().frame(maxWidth: .infinity) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
        .dreamPage()
        .page(Header("Add dream", leading: { BackButton(label: "Done") { dismiss() } }, trailing: { EmptyView() }), aboveBar: false)
        .task { await model.load(app) }
    }
}

// A pattern made by hand: the user's title and two or more supporting dreams, tagged or not; the AI writes only the analysis.
struct NewPatternView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let model: PatternsModel
    @State private var title = ""
    @State private var dreams: [JournalItem] = []
    @State private var picking = false
    var body: some View {
        let label = title.trimmingCharacters(in: .whitespacesAndNewlines)
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                TextField("Title", text: $title).field().accessibilityIdentifier("patternTitle")
                Heading("Supporting dreams")
                ForEach(dreams) { item in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) { Text(item.title ?? "Dream of \(displayDate(item.dreamDate))").font(.callout); Hint(shortDate(item.dreamDate)) }
                        Spacer()
                        Button { dreams.removeAll { $0.id == item.id } } label: { Image(systemName: "minus.circle").foregroundStyle(Color.muted) }
                            .buttonStyle(.plain).accessibilityLabel("Remove \(item.title ?? "dream")")
                    }
                }
                Button("+ Add dream") { picking = true }.buttonStyle(.quiet).accessibilityIdentifier("addPatternDream")
                if let error = model.error { Hint(error) }
                Button("Save pattern") { save(label) }.buttonStyle(.primary)
                    .disabled(label.isEmpty || label.count > app.limits.maxLabelChars || dreams.count < 2 || model.isSending)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
        .dreamPage()
        .page(Header("Add pattern", leading: { BackButton(label: "Cancel") { dismiss() } }, trailing: { EmptyView() }), aboveBar: false)
        .sheet(isPresented: $picking) {
            NavigationStack { DreamPickerView(excluded: Set(dreams.map(\.id))) { item in dreams.append(item) } }
        }
    }
    private func save(_ label: String) {
        Task { if await model.create(app, label: label, dreamIds: dreams.map(\.id)) { dismiss() } }
    }
}
