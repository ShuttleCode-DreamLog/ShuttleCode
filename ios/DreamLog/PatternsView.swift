import SwiftUI
import Observation

@MainActor @Observable
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
    private func change(_ app: AppModel, split: Bool = false, _ request: (APIClient) async -> Result<PatternsResponse, APIError>) async {
        guard !isSending, app.noticeSeen, !app.deleting, let client = app.client else { return }
        isSending = true; changes += 1
        let epoch = app.journalEpoch
        let result = await request(client)
        isSending = false
        guard epoch == app.journalEpoch, !app.deleting else { return }
        switch result {
        case let .success(value): response = value; error = nil
        case let .failure(failure):
            // A repeated split answers 409; the screen then reads the findings again and still says why.
            if split && failure.status == 409 { await load(app) }
            error = failure.message
        }
    }
    func rename(_ app: AppModel, _ finding: Finding, label: String) async {
        await change(app) { await $0.labelPattern(finding.groupId, PatternLabel(label: label)) }
    }
    func dismiss(_ app: AppModel, _ finding: Finding, dreamId: String, note: String) async {
        await change(app) { await $0.dismissPattern(finding.groupId, PatternDismissal(dreamId: dreamId, note: note)) }
    }
    func split(_ app: AppModel, _ finding: Finding, dreamIds: [String], label: String, note: String) async {
        await change(app, split: true) { await $0.splitPattern(finding.groupId, PatternSplit(dreamIds: dreamIds, label: label.isEmpty ? nil : label, note: note)) }
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
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 13) {
                    Picker("View", selection: $garden) {
                        Text("Garden").tag(true)
                        Text("List").tag(false)
                    }.pickerStyle(.segmented)
                    if let error = model.error { ErrorCard(error) { Task { await model.load(app) } } }
                    if let response = model.response {
                        Hint("\(displayDate(response.period.fromDate)) – \(displayDate(response.period.toDate)) · \(response.eligibleDreams) eligible recorded dreams")
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
    }
    // Garden: the same findings as plants sized by the number of distinct dreams that contain them (EGMUIUX S10).
    @ViewBuilder private func gardenBlock(_ response: PatternsResponse) -> some View {
        let current = response.findings.first { $0.groupId == selected } ?? response.findings.first
        BubbleCluster(bubbles: response.findings.map { Bubble(id: $0.groupId, label: $0.name, weight: Double($0.supportingDreams)) },
                      selected: current?.groupId) { selected = $0 }
            .padding(.vertical, 8)
        if let current {
            Heading("\(current.name) · \(current.supportingDreams) distinct dreams")
            ForEach(current.examples) { example in
                NavigationLink(value: Route.dream(example.dreamId)) { ExampleCard(example: example) }.buttonStyle(.plain)
            }
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
            ForEach(finding.examples.prefix(3)) { Text("· \($0.name)").font(.callout) }
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
struct PatternDetailView: View {
    @Environment(AppModel.self) private var app
    let groupId: String
    let model: PatternsModel
    @State private var renaming = false
    @State private var name = ""
    @State private var correcting = false
    @State private var moving: Set<String> = []
    @State private var newName = ""
    @State private var splitNote = ""
    @State private var confirmingSplit = false
    @State private var dismissing: FindingExample?
    @State private var dismissNote = ""
    private var finding: Finding? { model.response?.findings.first { $0.groupId == groupId } }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let error = model.error { ErrorCard(error) }
                if let response = model.response, let finding {
                    HStack {
                        Eyebrow("A thread across dreams")
                        Spacer()
                        Button("Rename") { name = finding.label ?? ""; renaming = true }.buttonStyle(.secondary)
                    }
                    Text("\(finding.periodCount) of \(response.eligibleDreams) eligible recorded dreams (\(displayDate(response.period.fromDate)) – \(displayDate(response.period.toDate))), in \(finding.supportingDreams) recorded dreams in all.")
                        .font(.callout)
                    if let trend = trendText(finding, response) { Hint(trend) }
                    Heading("Supporting dreams")
                    ForEach(finding.examples) { example in
                        NavigationLink(value: Route.dream(example.dreamId)) { ExampleCard(example: example) }.buttonStyle(.plain)
                    }
                    Heading("Summary & analysis")
                    if finding.status == .refreshing { Label("The explanation is being updated.", systemImage: "hourglass").font(.callout) }
                    else if let explanation = finding.explanation { Text(explanation).font(.callout) }
                    else { Hint("No explanation yet") }
                    if !finding.notes.isEmpty {
                        Hint("Your notes sent with this pattern")
                        ForEach(finding.notes, id: \.self) { Text($0).font(.callout) }
                    }
                    ForEach(finding.dismissalNotes, id: \.dreamId) { note in
                        HStack {
                            Text("Dismissal note: \(note.note)").font(.callout)
                            Spacer()
                            Button("Remove note") { Task { await model.dismiss(app, finding, dreamId: note.dreamId, note: "") } }.buttonStyle(.quiet)
                        }
                    }
                    DisclosureGroup("Correct this pattern", isExpanded: $correcting) { corrections(finding) }.font(.callout).padding(.top, 8)
                } else if model.response != nil {
                    EmptyCard("This pattern is no longer among the findings")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
        .dreamPage()
        .page(Header(finding?.name ?? "Pattern", leading: { BackButton() }, trailing: { HomeButton() }))
        .alert("Rename pattern", isPresented: $renaming) {
            TextField("Pattern name", text: $name)
            Button("Save") { rename() }
            if finding?.labelCorrected == true { Button("Use generated name") { if let finding { Task { await model.rename(app, finding, label: "") } } } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Corrections change the pattern, not your dream text.") }
        .confirmationDialog("The dreams you move will not be grouped with the others again, in either direction. A note written with a split cannot be removed later.", isPresented: $confirmingSplit, titleVisibility: .visible) {
            Button("Save Split") {
                guard let finding else { return }
                Task { await model.split(app, finding, dreamIds: Array(moving), label: newName.trimmingCharacters(in: .whitespacesAndNewlines), note: splitNote); moving = []; newName = ""; splitNote = "" }
            }
        }
        .alert("Not part of this pattern?", isPresented: Binding(get: { dismissing != nil }, set: { if !$0 { dismissing = nil } }), presenting: dismissing) { example in
            TextField("Why it does not belong (optional)", text: $dismissNote)
            Button("Dismiss", role: .destructive) { if let finding { Task { await model.dismiss(app, finding, dreamId: example.dreamId, note: dismissNote); dismissNote = "" } } }
            Button("Cancel", role: .cancel) {}
        } message: { example in
            Text("“\(example.name)” will not be put back into “\(finding?.name ?? "this pattern")”, and it will not be grouped again with the other \(max(0, (finding?.supportingDreams ?? 1) - 1)) dreams of this theme. This cannot be taken back. A note tells later matching why, and is sent to the AI service with the group.")
        }
    }
    private func rename() {
        guard let finding else { return }
        let label = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty, label.count <= app.limits.maxLabelChars else { model.error = "Give the pattern a name of 1 to \(app.limits.maxLabelChars) characters."; return }
        Task { await model.rename(app, finding, label: label) }
    }
    private func trendText(_ finding: Finding, _ response: PatternsResponse) -> String? {
        let comparison = "\(finding.periodCount) of \(response.eligibleDreams) now, \(finding.previousCount) of \(response.previousEligibleDreams) in the period before"
        return switch finding.trend {
        case .moreOftenRecordedRecently: "More often recorded recently: \(comparison)."
        case .lessOftenRecordedRecently: "Less often recorded recently: \(comparison)."
        case .same: "Recorded as often as before: \(comparison)."
        case .unknown, nil: nil
        }
    }
    @ViewBuilder private func corrections(_ finding: Finding) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Split: choose the dreams that belong to a separate group").font(.callout.weight(.semibold))
            ForEach(finding.examples) { example in
                Toggle(example.name, isOn: Binding(get: { moving.contains(example.dreamId) }, set: { if $0 { moving.insert(example.dreamId) } else { moving.remove(example.dreamId) } }))
            }
            TextField("Name of the new group (optional)", text: $newName).field()
            TextField("Note: why these do not belong together (optional)", text: $splitNote).field()
            Hint(splitPreview(finding))
            Button("Save Split") { confirmingSplit = true }.buttonStyle(.primary)
                .disabled(moving.isEmpty || moving.count >= finding.supportingDreams || splitNote.count > app.limits.maxPatternNoteChars)
        }.padding(.top, 10)
        VStack(alignment: .leading, spacing: 8) {
            Text("Dismiss a dream from this pattern").font(.callout.weight(.semibold))
            ForEach(finding.examples) { example in
                Button("Not part of this pattern: \(example.name)") { dismissing = example }.buttonStyle(.quiet)
            }
        }.padding(.top, 10)
    }
    private func splitPreview(_ finding: Finding) -> String {
        let remaining = finding.supportingDreams - moving.count
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        return "“\(finding.name)” keeps \(remaining) dream\(remaining == 1 ? "" : "s") · “\(name.isEmpty ? "New group" : name)” gets \(moving.count) dream\(moving.count == 1 ? "" : "s")"
    }
}
