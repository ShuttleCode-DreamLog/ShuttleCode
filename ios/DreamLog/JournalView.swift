import SwiftUI

struct JournalView: View {
    @Environment(AppModel.self) private var app
    @State private var model = JournalModel()
    @State private var path: [Route] = []
    @State private var query = ""
    @State private var creating: EntryRoute?
    @State private var filtering = false
    @State private var fromDate: Date?
    @State private var toDate: Date?
    @State private var tag = ""
    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    Button { creating = EntryRoute(id: newID()) } label: {
                        Label("Type a Dream", systemImage: "plus").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .accessibilityIdentifier("typeDream")
                    .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                }
                Section {
                    DisclosureGroup("Filter this journal", isExpanded: $filtering) {
                        dateField("From", date: $fromDate)
                        dateField("To", date: $toDate)
                        TextField("Tag, for example bridge", text: $tag).autocorrectionDisabled().textInputAutocapitalization(.never)
                        HStack {
                            Button("Apply Filters") { applyFilters() }.buttonStyle(.bordered)
                            Spacer()
                            Button("Clear Filters") { clearFilters() }.buttonStyle(.bordered).disabled(model.filter.tag == nil && model.filter.fromDate == nil && model.filter.toDate == nil)
                        }
                    }
                } footer: { Text(filterSummary) }
                if let error = model.error {
                    Section {
                        Text(error).foregroundStyle(.red)
                        Text("Dreams saved on this device are sent when the connection returns.").font(.footnote)
                        Button("Try again") { Task { await model.load(app) } }
                    }
                }
                if model.rows.isEmpty && !model.isLoading {
                    ContentUnavailableView(model.filter.isEmpty ? "No dreams yet" : "No recorded dream matches", systemImage: "book",
                                           description: Text(model.filter.isEmpty ? "Tap Type a Dream to keep your first dream." : "Clear the search or filters to see every dream."))
                }
                ForEach(model.rows) { row in
                    NavigationLink(value: row.opensEditor ? Route.draft(row.id) : Route.dream(row.id)) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(row.title).font(.headline)
                            Text([row.date.isEmpty ? nil : displayDate(row.date), row.preview.isEmpty ? nil : row.preview].compactMap(\.self).joined(separator: " · "))
                                .lineLimit(3)
                            Text(row.statusText).font(.caption)
                                .foregroundStyle(row.status == .needsAttention || row.draft?.conflict == true ? .orange : .secondary)
                        }.padding(.vertical, 4)
                    }
                }
                if model.hasMore {
                    Button("Load more") { Task { await model.load(app, more: true) } }
                        .disabled(model.isLoading)
                        .onAppear { Task { await model.load(app, more: true) } }
                }
                if model.isLoading { ProgressView() }
            }
            .dreamPage()
            .navigationTitle("Journal")
            .searchable(text: $query, prompt: "Search dream text")
            .onSubmit(of: .search) {
                guard !model.isLoading else { return }
                model.filter.query = query
                Task { await model.load(app) }
            }
            .onChange(of: query) { _, value in
                if value.isEmpty && !model.filter.query.isEmpty {
                    model.filter.query = ""
                    Task { await model.load(app) }
                }
            }
            .toolbar { ToolbarItem(placement: .topBarTrailing) { SettingsButton() } }
            .routeDestinations()
            .sheet(item: $creating, onDismiss: { Task { await model.load(app) } }) { entry in
                NavigationStack { DreamEditorView(id: entry.id, newEntry: true) }
            }
            .refreshable { await model.load(app) }
            .task { await model.load(app) }
            .onChange(of: path) { _, value in if value.isEmpty { Task { await model.load(app) } } }
            .onChange(of: app.refreshes) { Task { await model.load(app) } }
            .onChange(of: app.requestedTag, initial: true) { _, requested in
                guard let requested else { return }
                app.requestedTag = nil
                tag = requested; filtering = true
                model.filter.tag = requested
                if path.isEmpty { Task { await model.load(app) } } else { path = [] }
            }
        }
    }
    @ViewBuilder private func dateField(_ title: String, date: Binding<Date?>) -> some View {
        Toggle(title, isOn: Binding(get: { date.wrappedValue != nil }, set: { date.wrappedValue = $0 ? .now : nil }))
        if let value = date.wrappedValue {
            DatePicker("\(title) date", selection: Binding(get: { value }, set: { date.wrappedValue = $0 }), displayedComponents: .date)
        }
    }
    private func applyFilters() {
        let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        model.filter.tag = trimmed.isEmpty ? nil : trimmed
        model.filter.fromDate = fromDate.map { journalDate($0) }
        model.filter.toDate = toDate.map { journalDate($0) }
        Task { await model.load(app) }
    }
    private func clearFilters() {
        fromDate = nil; toDate = nil; tag = ""
        model.filter.tag = nil; model.filter.fromDate = nil; model.filter.toDate = nil
        Task { await model.load(app) }
    }
    private var filterSummary: String {
        let filter = model.filter
        let parts = [filter.query.isEmpty ? nil : "matching “\(filter.query)”", filter.fromDate.map { "from \(displayDate($0))" },
                     filter.toDate.map { "to \(displayDate($0))" }, filter.tag.map { "tagged “\($0)”" }].compactMap(\.self)
        return parts.isEmpty ? "Showing all dreams. Apply Filters to narrow the list." : "Showing dreams \(parts.joined(separator: " "))."
    }
}
