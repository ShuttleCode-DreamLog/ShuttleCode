import SwiftUI

struct JournalView: View {
    @Environment(AppModel.self) private var app
    @State private var model = JournalModel()
    @State private var path: [Route] = []
    @State private var query = ""
    @State private var filtering = false
    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 13) {
                    HStack(spacing: 10) {
                        TextField("Search dreams…", text: $query).field().submitLabel(.search).onSubmit(search)
                        Button("Filter") { filtering = true }.buttonStyle(.secondary)
                    }
                    if let error = model.error {
                        ErrorCard("\(error) Dreams saved on this device are sent when the connection returns.") { Task { await model.load(app) } }
                    }
                    Hint(countLine)
                    if model.rows.isEmpty && !model.isLoading {
                        EmptyCard(model.filter.isEmpty ? "No dreams yet" : "No recorded dream matches")
                    }
                    ForEach(model.rows) { row in
                        NavigationLink(value: row.opensEditor ? Route.draft(row.id) : Route.dream(row.id)) { DreamCard(row: row) }.buttonStyle(.plain)
                    }
                    if model.hasMore {
                        Button("Load more") { Task { await model.load(app, more: true) } }.buttonStyle(.secondary)
                            .disabled(model.isLoading)
                            .onAppear { Task { await model.load(app, more: true) } }
                    }
                    if model.isLoading { ProgressView().frame(maxWidth: .infinity) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
            }
            .dreamPage()
            .page(Header("Journal") { HomeButton() })
            .routeDestinations()
            .sheet(isPresented: $filtering) { JournalFilterSheet(model: model) }
            .reloadable { await model.load(app) }
            .task { await model.load(app) }
            .onChange(of: query) { _, value in
                if value.isEmpty && !model.filter.query.isEmpty { model.filter.query = ""; Task { await model.load(app) } }
            }
            .onChange(of: path) { _, value in if value.isEmpty { Task { await model.load(app) } } }
            .onChange(of: app.refreshes) { Task { await model.load(app) } }
            .onChange(of: app.requestedTag, initial: true) { _, requested in
                guard let requested else { return }
                app.requestedTag = nil
                model.filter.tag = requested
                if path.isEmpty { Task { await model.load(app) } } else { path = [] }
            }
            .onChange(of: app.requestedMood, initial: true) { _, requested in
                guard let requested else { return }
                app.requestedMood = nil
                model.filter.mood = requested
                if path.isEmpty { Task { await model.load(app) } } else { path = [] }
            }
        }
    }
    private func search() {
        guard !model.isLoading else { return }
        model.filter.query = query
        Task { await model.load(app) }
    }
    private var countLine: String {
        let count = model.rows.count
        let entries = "\(count)\(model.hasMore ? "+" : "") \(count == 1 ? "entry" : "entries")"
        let filter = model.filter
        let parts = [filter.query.isEmpty ? nil : "matching “\(filter.query)”", filter.mood.map { "feeling \($0.rawValue)" },
                     filter.fromDate.map { "from \(displayDate($0))" }, filter.toDate.map { "to \(displayDate($0))" },
                     filter.tag.map { "tagged “\($0)”" }].compactMap(\.self)
        return (parts.isEmpty ? "All dreams" : "Dreams \(parts.joined(separator: " "))") + " · \(entries)"
    }
}

// The prototype's dream card: date, title, tag pills, summary and a motif.
struct DreamCard: View {
    let row: JournalRow
    var body: some View {
        let mood = row.draft?.mood ?? row.item?.mood
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                if !row.date.isEmpty { Hint(shortDate(row.date)) }
                Text(row.title).font(.heading)
                if !row.tags.isEmpty {
                    Wrap(spacing: 4) { ForEach(row.tags.prefix(4), id: \.self) { Pill($0.text) } }
                } else if let mood, mood != .unknown { Pill(mood.rawValue.capitalized) }
                if !row.preview.isEmpty { Text(row.preview).font(.callout).foregroundStyle(Color.muted).lineLimit(3) }
                if row.status != .saved {
                    Text(row.statusText).font(.caption2)
                        .foregroundStyle(row.status == .needsAttention || row.draft?.conflict == true ? Color.danger : Color.muted)
                }
            }
            Spacer(minLength: 0)
            Text(glyph(mood)).font(.glyph).foregroundStyle(Color.motif)
        }
        .multilineTextAlignment(.leading)
        .card()
    }
}

struct JournalFilterSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let model: JournalModel
    @State private var mood: Mood?
    @State private var tag = ""
    @State private var fromDate: Date?
    @State private var toDate: Date?
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 13) {
                    LabeledRow("Feeling") {
                        Picker("Feeling", selection: $mood) {
                            Text("Any").tag(Mood?.none)
                            ForEach(Mood.allCases.filter { $0 != .unknown }, id: \.self) { Text($0.rawValue.capitalized).tag(Optional($0)) }
                        }.labelsHidden()
                    }
                    TextField("Tag", text: $tag).field().autocorrectionDisabled().textInputAutocapitalization(.never)
                    dateRow("From", date: $fromDate)
                    dateRow("To", date: $toDate)
                    HStack(spacing: 10) {
                        Button("Apply") { apply(); dismiss() }.buttonStyle(.primary)
                        Button("Clear") { clear(); dismiss() }.buttonStyle(.secondary)
                            .disabled(model.filter.tag == nil && model.filter.mood == nil && model.filter.fromDate == nil && model.filter.toDate == nil)
                    }.padding(.top, 8)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
            }
            .dreamPage()
            .page(Header("Filter dreams", leading: { BackButton(label: "Cancel") }, trailing: { EmptyView() }), aboveBar: false)
            .onAppear {
                mood = model.filter.mood; tag = model.filter.tag ?? ""
                fromDate = model.filter.fromDate.map(journalDay); toDate = model.filter.toDate.map(journalDay)
            }
        }
        .presentationDetents([.medium, .large])
    }
    @ViewBuilder private func dateRow(_ title: String, date: Binding<Date?>) -> some View {
        Toggle("\(title) date", isOn: Binding(get: { date.wrappedValue != nil }, set: { date.wrappedValue = $0 ? .now : nil })).font(.callout).switchRow()
        if let value = date.wrappedValue {
            LabeledRow(title) {
                DatePicker("\(title) date", selection: Binding(get: { value }, set: { date.wrappedValue = $0 }), displayedComponents: .date).labelsHidden()
            }
        }
    }
    private func apply() {
        let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        model.filter.tag = trimmed.isEmpty ? nil : trimmed
        model.filter.mood = mood
        model.filter.fromDate = fromDate.map { journalDate($0) }
        model.filter.toDate = toDate.map { journalDate($0) }
        Task { await model.load(app) }
    }
    private func clear() {
        model.filter.tag = nil; model.filter.mood = nil; model.filter.fromDate = nil; model.filter.toDate = nil
        Task { await model.load(app) }
    }
}
