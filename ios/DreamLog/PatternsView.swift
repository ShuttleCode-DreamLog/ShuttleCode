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

struct PatternsView: View {
    @Environment(AppModel.self) private var app
    @State private var model = PatternsModel()
    @State private var path: [Route] = []
    @State private var garden = false
    @State private var selected: String?
    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    Picker("View", selection: $garden) {
                        Text("List").tag(false)
                        Text("Garden").tag(true)
                    }.pickerStyle(.segmented)
                } footer: { Text(periodText) }
                if let error = model.error {
                    Section { Text(error).foregroundStyle(.red); Button("Try again") { Task { await model.load(app) } } }
                }
                if let response = model.response {
                    if !response.available {
                        Section { Text("New matching is not available on the server at the moment. Patterns found earlier are still shown.").font(.callout) }
                    }
                    if let task = response.task, task.status == .failed {
                        Section {
                            Text("The findings could not be updated. \(failureText(task))").font(.callout)
                            Button("Retry") { Task { await model.retry(app) } }
                        }
                    }
                    if response.insufficientHistory {
                        ContentUnavailableView("Not enough recorded history yet", systemImage: "leaf",
                                               description: Text("A pattern appears once two or more of your dreams share a person, place, feeling or theme. Keep recording."))
                    } else if garden {
                        gardenSection(response)
                    } else {
                        ForEach(response.findings) { finding in FindingSection(finding: finding, response: response, model: model) }
                    }
                } else if model.isLoading { ProgressView("Looking for patterns…") }
            }
            .dreamPage()
            .navigationTitle("Patterns")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { SettingsButton() } }
            .routeDestinations()
            .disabled(model.isSending)
            .refreshable { await model.load(app) }
            .task { await model.load(app) }
            .onChange(of: path) { _, value in if value.isEmpty { Task { await model.load(app) } } }
            .onChange(of: app.refreshes) { Task { await model.load(app) } }
        }
    }
    private var periodText: String {
        guard let response = model.response else { return "Patterns come from your recorded dreams; nothing needs to be started." }
        return "\(displayDate(response.period.fromDate)) – \(displayDate(response.period.toDate)) · \(response.eligibleDreams) eligible recorded dreams. Findings are possibilities, not proof of a shared meaning."
    }

    // Garden: the same findings as plants sized by the number of distinct dreams that contain them (EGMUIUX S10).
    @ViewBuilder private func gardenSection(_ response: PatternsResponse) -> some View {
        let largest = Double(response.findings.map(\.supportingDreams).max() ?? 1)
        let current = response.findings.first { $0.groupId == selected } ?? response.findings.first
        Section {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 12)], spacing: 16) {
                ForEach(response.findings) { finding in
                    let chosen = finding.groupId == current?.groupId
                    let size = 64 + 56 * Double(finding.supportingDreams) / largest
                    Button { selected = finding.groupId } label: {
                        VStack(spacing: 4) {
                            Circle()
                                .fill(chosen ? Color.duskFill : Color(uiColor: .secondarySystemGroupedBackground))
                                .strokeBorder(Color.dusk, style: StrokeStyle(lineWidth: chosen ? 2 : 1, dash: finding.kind == .recurring ? [] : [4, 3]))
                                .frame(width: size, height: size)
                                .overlay { Text(finding.name).font(.caption.weight(chosen ? .bold : .regular)).multilineTextAlignment(.center).padding(6) }
                            Rectangle().fill(Color.dusk.opacity(0.4)).frame(width: 2, height: 14)
                            Text("\(finding.supportingDreams) dreams").font(.caption2).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(finding.name), \(finding.supportingDreams) dreams\(chosen ? ", selected" : "")")
                }
            }.padding(.vertical, 8)
        } footer: { Text("Each plant is a theme found in your dreams; its size shows how many distinct dreams contain it. Dashed plants are related examples that do not yet recur.") }
        if let current {
            Section {
                ForEach(current.examples) { example in NavigationLink(value: Route.dream(example.dreamId)) { ExampleRow(example: example) } }
            } header: { Text("\(current.name) · \(current.supportingDreams) distinct dreams") } footer: { Text("Tap a dream to open it. Rename, split and dismiss are in List view.") }
        }
    }
}

struct ExampleRow: View {
    let example: FindingExample
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(example.name) · \(displayDate(example.dreamDate))").font(.subheadline.weight(.semibold))
            Text("“\(example.excerpt)”")
            if let shared = example.sharedElement { Text("Shared: \(shared)").font(.caption).foregroundStyle(.secondary) }
            if let difference = example.difference { Text("Different: \(difference)").font(.caption).foregroundStyle(.secondary) }
        }
    }
}

struct FindingSection: View {
    @Environment(AppModel.self) private var app
    let finding: Finding
    let response: PatternsResponse
    let model: PatternsModel
    @State private var correcting = false
    @State private var name = ""
    @State private var moving: Set<String> = []
    @State private var newName = ""
    @State private var splitNote = ""
    @State private var confirmingSplit = false
    @State private var dismissing: FindingExample?
    @State private var dismissNote = ""
    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text(finding.kind == .recurring ? "Recurring theme" : "Related examples").font(.caption.weight(.semibold)).foregroundStyle(Color.dusk)
                Text("\(finding.periodCount) of \(response.eligibleDreams) eligible recorded dreams (\(displayDate(response.period.fromDate)) – \(displayDate(response.period.toDate))), in \(finding.supportingDreams) recorded dreams in all.")
                    .font(.callout)
                if let trend = trendText { Text(trend).font(.caption).foregroundStyle(.secondary) }
                if finding.status == .refreshing { Label("The explanation is being updated.", systemImage: "hourglass").font(.caption) }
                else if let explanation = finding.explanation { Text(explanation) }
            }
            ForEach(finding.examples) { example in NavigationLink(value: Route.dream(example.dreamId)) { ExampleRow(example: example) } }
            if !finding.notes.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Your notes sent with this pattern").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(finding.notes, id: \.self) { Text($0).font(.callout) }
                }
            }
            ForEach(finding.dismissalNotes, id: \.dreamId) { note in
                HStack {
                    Text("Dismissal note: \(note.note)").font(.callout)
                    Spacer()
                    Button("Remove note") { Task { await model.dismiss(app, finding, dreamId: note.dreamId, note: "") } }.buttonStyle(.borderless)
                }
            }
            DisclosureGroup("Correct this pattern", isExpanded: $correcting) { corrections }
        } header: { Text(finding.name).font(.headline).textCase(nil) }
        .onAppear { name = finding.label ?? "" }
        .onChange(of: finding.label) { _, value in name = value ?? "" }
        .confirmationDialog(splitLine, isPresented: $confirmingSplit, titleVisibility: .visible) {
            Button("Save Split") {
                Task { await model.split(app, finding, dreamIds: Array(moving), label: newName.trimmingCharacters(in: .whitespacesAndNewlines), note: splitNote); moving = []; newName = ""; splitNote = "" }
            }
        }
        .alert("Not part of this pattern?", isPresented: Binding(get: { dismissing != nil }, set: { if !$0 { dismissing = nil } }), presenting: dismissing) { example in
            TextField("Why it does not belong (optional)", text: $dismissNote)
            Button("Dismiss", role: .destructive) { Task { await model.dismiss(app, finding, dreamId: example.dreamId, note: dismissNote); dismissNote = "" } }
            Button("Cancel", role: .cancel) {}
        } message: { example in
            Text("“\(example.name)” will not be put back into “\(finding.name)”, and it will not be grouped again with the other \(finding.supportingDreams - 1) dreams of this theme. This cannot be taken back. A note tells later matching why, and is sent to the AI service with the group.")
        }
    }
    private var trendText: String? {
        let comparison = "\(finding.periodCount) of \(response.eligibleDreams) now, \(finding.previousCount) of \(response.previousEligibleDreams) in the period before"
        return switch finding.trend {
        case .moreOftenRecordedRecently: "More often recorded recently: \(comparison)."
        case .lessOftenRecordedRecently: "Less often recorded recently: \(comparison)."
        case .same: "Recorded as often as before: \(comparison)."
        case .unknown, nil: nil
        }
    }
    private var splitLine: String {
        "The dreams you move will not be grouped with the others again, in either direction. A note written with a split cannot be removed later."
    }
    @ViewBuilder private var corrections: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Pattern name", text: $name)
            HStack {
                Button("Save Name") { Task { await model.rename(app, finding, label: name.trimmingCharacters(in: .whitespacesAndNewlines)) } }
                    .buttonStyle(.borderedProminent).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.count > app.limits.maxLabelChars)
                Button("Cancel") { name = finding.label ?? "" }.buttonStyle(.bordered)
                if finding.labelCorrected { Button("Use generated name") { Task { await model.rename(app, finding, label: "") } }.buttonStyle(.bordered) }
            }
            Text("Corrections change the pattern, not your dream text.").font(.caption).foregroundStyle(.secondary)
        }
        VStack(alignment: .leading, spacing: 8) {
            Text("Split: choose the dreams that belong to a separate group").font(.subheadline.weight(.semibold))
            ForEach(finding.examples) { example in
                Toggle(example.name, isOn: Binding(get: { moving.contains(example.dreamId) }, set: { if $0 { moving.insert(example.dreamId) } else { moving.remove(example.dreamId) } }))
            }
            TextField("Name of the new group (optional)", text: $newName)
            TextField("Note: why these do not belong together (optional)", text: $splitNote)
            Text(splitPreview).font(.caption).foregroundStyle(.secondary)
            Button("Save Split") { confirmingSplit = true }
                .buttonStyle(.borderedProminent)
                .disabled(moving.isEmpty || moving.count >= finding.supportingDreams || splitNote.count > app.limits.maxPatternNoteChars)
        }
        VStack(alignment: .leading, spacing: 8) {
            Text("Dismiss a dream from this pattern").font(.subheadline.weight(.semibold))
            ForEach(finding.examples) { example in
                Button("Not part of this pattern: \(example.name)") { dismissing = example }.buttonStyle(.borderless)
            }
            Text("If two different people were treated as one, correct the tag on the dream's screen, or dismiss or split here with a note.").font(.caption).foregroundStyle(.secondary)
        }
    }
    private var splitPreview: String {
        let remaining = finding.supportingDreams - moving.count
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        return "Preview: “\(finding.name)” keeps \(remaining) dream\(remaining == 1 ? "" : "s") · “\(name.isEmpty ? "New group" : name)” gets \(moving.count) dream\(moving.count == 1 ? "" : "s"). A group with one dream is not yet recurring and is not shown."
    }
}
