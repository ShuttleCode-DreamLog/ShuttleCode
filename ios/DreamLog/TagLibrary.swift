import SwiftUI
import Observation

nonisolated struct LibraryTag: Codable, Sendable, Identifiable {
    var id: String
    var text: String
    var color: String
}
nonisolated struct TagLibraryResponse: Decodable { var tags: [LibraryTag] }
nonisolated struct LibraryTagResponse: Decodable { var tag: LibraryTag }
nonisolated struct LibraryTagName: Encodable { var text: String }
nonisolated struct DreamTagSelection: Encodable { var tagIds: [String] }

extension LibraryTag {
    var tint: Color {
        switch color {
        case "blue": .init(red: 0.48, green: 0.69, blue: 0.91)
        case "rose": .init(red: 0.91, green: 0.56, blue: 0.64)
        case "amber": .init(red: 0.94, green: 0.75, blue: 0.39)
        case "violet": .init(red: 0.72, green: 0.61, blue: 0.90)
        case "teal": .init(red: 0.38, green: 0.78, blue: 0.76)
        default: .init(red: 0.66, green: 0.79, blue: 0.55)
        }
    }
}

@MainActor @Observable
final class TagLibraryModel {
    var tags: [LibraryTag] = []
    var busy = false
    var loaded = false
    var error: String?
    func load(_ app: AppModel) async {
        guard !busy, app.noticeSeen, !app.deleting, let client = app.client else { return }
        busy = true
        defer { busy = false }
        let epoch = app.journalEpoch
        let result = await client.loadTagLibrary()
        guard epoch == app.journalEpoch, !app.deleting else { return }
        switch result {
        case let .success(value): tags = value.tags; loaded = true; error = nil
        case let .failure(failure): error = failure.message
        }
    }
    func create(_ app: AppModel, text: String) async -> LibraryTag? {
        guard !busy, app.noticeSeen, !app.deleting, let client = app.client else { return nil }
        busy = true
        defer { busy = false }
        let epoch = app.journalEpoch
        let result = await client.createLibraryTag(text)
        guard epoch == app.journalEpoch, !app.deleting else { return nil }
        switch result {
        case let .success(tag):
            if !tags.contains(where: { $0.id == tag.id }) { tags.append(tag) }
            error = nil; return tag
        case let .failure(failure): error = failure.message; return nil
        }
    }
    func rename(_ app: AppModel, tag: LibraryTag, text: String) async {
        guard !busy, app.noticeSeen, !app.deleting, let client = app.client else { return }
        busy = true
        defer { busy = false }
        let epoch = app.journalEpoch
        let result = await client.renameLibraryTag(tag.id, text: text)
        guard epoch == app.journalEpoch, !app.deleting else { return }
        switch result {
        case let .success(value): tags = value.tags; app.refreshes += 1; error = nil
        case let .failure(failure): error = failure.message
        }
    }
    func delete(_ app: AppModel, tag: LibraryTag) async -> Bool {
        guard !busy, app.noticeSeen, !app.deleting, let client = app.client else { return false }
        busy = true
        defer { busy = false }
        let epoch = app.journalEpoch
        let result = await client.deleteLibraryTag(tag.id)
        guard epoch == app.journalEpoch, !app.deleting else { return false }
        switch result {
        case .success: tags.removeAll { $0.id == tag.id }; app.refreshes += 1; error = nil; return true
        case let .failure(failure): error = failure.message; return false
        }
    }
}

struct TagSelectionControl: View {
    @Environment(AppModel.self) private var app
    let selectedIDs: [String]
    var initialTags: [LibraryTag] = []
    let save: ([String]) async -> Bool
    @State private var library = TagLibraryModel()
    @State private var showing = false

    var body: some View {
        Wrap(spacing: 6) {
            ForEach(selectedIDs, id: \.self) { id in
                if let tag = (library.loaded ? library.tags : initialTags).first(where: { $0.id == id }) {
                    Button { showing = true } label: { Pill(tag.text) }.buttonStyle(.plain)
                }
            }
            Button { showing = true } label: { Pill("+ Add tag") }
                .buttonStyle(.plain).accessibilityIdentifier("addTag")
        }
        .fullScreenCover(isPresented: $showing) {
            TagLibraryOverlay(library: library, selectedIDs: selectedIDs, save: save)
                .presentationBackground(.regularMaterial)
                .preferredColorScheme(.dark)
        }
        .task { await library.load(app) }
        .onChange(of: app.refreshes) { Task { await library.load(app) } }
    }
}

private struct TagLibraryOverlay: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let library: TagLibraryModel
    let selectedIDs: [String]
    let save: ([String]) async -> Bool
    @State private var selected: Set<String> = []
    @State private var saving = false
    @State private var saveError = false
    @State private var editingName = false
    @State private var editingTag: LibraryTag?
    @State private var deleting: LibraryTag?
    @State private var name = ""
    @ScaledMetric(relativeTo: .body) private var dotSize = 17
    private var validName: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.unicodeScalars.count <= app.limits.maxTagChars
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                Text("Tags").font(.system(size: 30, design: .serif))
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Done") {
                    Task {
                        saving = true; saveError = false
                        let ids = library.tags.filter { selected.contains($0.id) }.map(\.id)
                        if await save(ids) { dismiss() } else { saveError = true }
                        saving = false
                    }
                }.fontWeight(.semibold).disabled(!library.loaded).accessibilityIdentifier("tagLibraryDone")
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(library.tags) { tag in
                        HStack(spacing: 12) {
                            Button {
                                if selected.contains(tag.id) { selected.remove(tag.id) }
                                else if selected.count < 50 { selected.insert(tag.id) }
                            } label: {
                                HStack(spacing: 14) {
                                    Circle().fill(tag.tint).frame(width: dotSize, height: dotSize)
                                    Text(tag.text).font(.body).multilineTextAlignment(.leading)
                                    Spacer()
                                    if selected.contains(tag.id) { Image(systemName: "checkmark").font(.body.weight(.semibold)) }
                                }.contentShape(Rectangle()).padding(.vertical, 14)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(tag.text)
                            .accessibilityAddTraits(selected.contains(tag.id) ? .isSelected : [])
                            Menu {
                                Button("Rename", systemImage: "pencil") { editingTag = tag; name = tag.text; editingName = true }
                                Button("Delete from tag library", systemImage: "trash", role: .destructive) { deleting = tag }
                            } label: {
                                Image(systemName: "ellipsis").frame(width: 44, height: 44).contentShape(Rectangle())
                            }.accessibilityLabel("Manage \(tag.text)")
                        }
                    }
                    Button {
                        editingTag = nil; name = ""; editingName = true
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "plus").frame(width: dotSize)
                            Text("Add another tag")
                        }.padding(.vertical, 14).frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(.plain).disabled(!library.loaded)
                        .accessibilityIdentifier("addAnotherTag")
                }
            }
            .accessibilityIdentifier("tagLibraryList")
            if library.busy || saving { ProgressView().tint(.white) }
            if let error = library.error {
                Text(error).font(.callout)
                Button("Retry") { Task { await library.load(app) } }
            }
            if saveError { Text("Your selection could not be saved. Try Done again.").font(.callout) }
            if selected.count >= 50 { Text("Choose up to 50 tags per dream.").font(.caption) }
        }
        .padding(24)
        .foregroundStyle(.white)
        .tint(.white)
        .disabled(library.busy || saving)
        .interactiveDismissDisabled(saving || library.busy)
        .task {
            selected = Set(selectedIDs)
            await library.load(app)
            if library.loaded { selected.formIntersection(Set(library.tags.map(\.id))) }
        }
        .alert(editingTag == nil ? "Add another tag" : "Rename tag", isPresented: $editingName) {
            TextField("Tag name", text: $name)
            Button("Save") {
                Task {
                    if let editingTag { await library.rename(app, tag: editingTag, text: name) }
                    else if let tag = await library.create(app, text: name) { selected.insert(tag.id) }
                }
            }.disabled(!validName || (editingTag == nil && selected.count >= 50))
            Button("Cancel", role: .cancel) {}
        } message: { Text(editingTag == nil ? "Saved to your tag library for use in any dream." : "This changes the tag name in every dream that uses it.") }
        .confirmationDialog("Delete this tag from your library and all dreams that use it?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible, presenting: deleting) { tag in
            Button("Delete tag", role: .destructive) {
                Task { if await library.delete(app, tag: tag) { selected.remove(tag.id) } }
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}
