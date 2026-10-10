import SwiftUI

struct JournalView: View {
    @Environment(AppModel.self) private var app
    @State private var model = JournalModel()
    @State private var path: [String] = []
    @State private var query = ""
    @State private var creating: EntryRoute?
    var body: some View {
        NavigationStack(path: $path) {
            List {
                if let error = model.error {
                    Section {
                        Text(error).foregroundStyle(.red)
                        Text("Unsent drafts remain on this phone.").font(.footnote)
                        Button("Try again") { Task { await model.load(app) } }
                    }
                }
                if model.rows.isEmpty && !model.isLoading {
                    ContentUnavailableView("No journal entries", systemImage: "book", description: Text("Tap + to write your first entry."))
                }
                ForEach(model.rows) { row in
                    NavigationLink(value: row.id) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(row.title).font(.headline)
                            Text(row.preview).lineLimit(3).foregroundStyle(.secondary)
                            HStack {
                                Text(row.date)
                                Spacer()
                                Text(row.status).foregroundStyle(row.draft?.unsent == true ? .orange : .secondary)
                            }.font(.caption)
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
            .navigationTitle("Journal")
            .searchable(text: $query, prompt: "Search journal text")
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
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("New journal entry", systemImage: "plus") { creating = EntryRoute(id: newID()) }
                }
            }
            .navigationDestination(for: String.self) { id in DreamEditorView(id: id) }
            .sheet(item: $creating, onDismiss: { Task { await model.load(app) } }) { entry in
                NavigationStack { DreamEditorView(id: entry.id, newEntry: true) }
            }
            .refreshable { await model.load(app) }
            .task { await model.load(app) }
            .onChange(of: path) { _, value in if value.isEmpty { Task { await model.load(app) } } }
        }
    }
}
