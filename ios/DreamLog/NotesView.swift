import SwiftUI
import PhotosUI

nonisolated func noteLabel(_ note: Memory) -> String { note.title?.isEmpty == false ? note.title! : "Note" }

struct NotesView: View {
    @Environment(AppModel.self) private var app
    @State private var model = NotesModel()
    @State private var path: [String] = []
    @State private var creating: EntryRoute?
    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 13) {
                    Eyebrow("Your waking world")
                    PageHeading("Small moments matter.")
                    if let error = model.error { ErrorCard(error) { Task { await model.load(app) } } }
                    if model.items.isEmpty && !model.isLoading { EmptyCard("No notes yet") }
                    ForEach(model.items) { note in NavigationLink(value: note.id) { NoteCard(note: note) }.buttonStyle(.plain) }
                    if model.hasMore {
                        Button("Load more") { Task { await model.load(app, more: true) } }.buttonStyle(.secondary).disabled(model.isLoading)
                    }
                    if model.isLoading { ProgressView().frame(maxWidth: .infinity) }
                    Button("Add note") { creating = EntryRoute(id: newID()) }.buttonStyle(.primaryWide).accessibilityIdentifier("addNote")
                    HistoryToggle().font(.callout).switchRow()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
            }
            .dreamPage()
            .page(Header("Life notes") { HomeButton() })
            .navigationDestination(for: String.self) { NoteEditorView(id: $0) }
            .sheet(item: $creating, onDismiss: { Task { await model.load(app) } }) { entry in
                NavigationStack { NoteEditorView(id: entry.id, newEntry: true) }
            }
            .task { await model.load(app) }
            .reloadable { await model.load(app) }
            .onChange(of: path) { _, value in if value.isEmpty { Task { await model.load(app) } } }
            .onChange(of: app.refreshes) { Task { await model.load(app) } }
        }
    }
}

struct NoteCard: View {
    let note: Memory
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Hint([note.eventDate.map(shortDate) ?? note.recordedAt.formatted(.dateTime.month(.abbreviated).day()), note.isOngoing ? "Ongoing" : nil]
                .compactMap(\.self).joined(separator: " · "))
            Text(noteLabel(note)).font(.heading)
            Text(note.text.isEmpty ? "Photo note" : note.text).font(.callout).lineLimit(3)
            let details = [note.allowAnalysis ? nil : "AI use off", note.photos.isEmpty ? nil : "\(note.photos.count) photo\(note.photos.count == 1 ? "" : "s")"].compactMap(\.self)
            if !details.isEmpty { Hint(details.joined(separator: " · ")) }
        }
        .multilineTextAlignment(.leading)
        .card()
    }
}

// The prototype's note page (date, Edit, text) and note editor (title, date, text, Cancel and Save note); the rest folds under More.
struct NoteEditorView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var model: NoteEditorModel
    @State private var confirmingDelete = false
    @State private var confirmingClose = false
    @State private var showingSaveError = false
    @State private var showMore = false
    @FocusState private var writingText: Bool
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var removingPhoto: String?
    let newEntry: Bool
    init(id: String, newEntry: Bool = false) {
        _model = State(initialValue: NoteEditorModel(id: id, newEntry: newEntry))
        self.newEntry = newEntry
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 13) {
                if model.isLoading { ProgressView() }
                if let error = model.error {
                    if model.isEditing { ErrorCard(error) } else { ErrorCard(error, retry: reload) }
                }
                if model.isEditing { editingBlock } else if let stored = model.stored { readingBlock(stored) }
                photosBlock
                if model.isEditing {
                    HStack(spacing: 10) {
                        Button("Cancel") { cancel() }.buttonStyle(.secondary)
                        Button("Save note") { Task { await save() } }.buttonStyle(.primary).disabled(!model.canSave(app)).accessibilityIdentifier("saveNote")
                    }.padding(.top, 8)
                } else if model.stored != nil {
                    Button("Delete note", role: .destructive) { confirmingDelete = true }.buttonStyle(.quiet).padding(.top, 8)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
        .dreamPage()
        .page(header, aboveBar: !newEntry)
        .disabled(model.isSending)
        .task { await model.load(app) }
        .interactiveDismissDisabled(model.hasChanges || model.isSending || model.isAddingPhotos)
        .onChange(of: selectedPhotos) { _, items in
            if !items.isEmpty { Task { await model.addPhotos(items, app: app); selectedPhotos = [] } }
        }
        .confirmationDialog("Remove this photo?", isPresented: Binding(get: { removingPhoto != nil }, set: { if !$0 { removingPhoto = nil } }), titleVisibility: .visible, presenting: removingPhoto) { photoID in
            Button("Remove photo", role: .destructive) { Task { await model.deletePhoto(photoID, app: app) } }
        }
        .confirmationDialog("Delete this life note?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete note", role: .destructive) { Task { await model.delete(app); if model.deleted { dismiss() } } }
        }
        .confirmationDialog("This note has unsaved changes.", isPresented: $confirmingClose, titleVisibility: .visible) {
            Button("Save and close") { Task { await save(close: true) } }.disabled(!model.canSave(app))
            Button("Discard", role: .destructive) { dismiss() }
            Button("Keep editing", role: .cancel) {}
        }
        .alert("Could not save note", isPresented: $showingSaveError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.error ?? "The note was not saved. Your input is still here; try again.")
        }
    }
    @ViewBuilder private var header: some View {
        let title = model.isEditing ? (newEntry ? "New note" : "Edit note") : (model.stored.map(noteLabel) ?? "Note")
        if newEntry {
            Header(title, leading: { BackButton(label: "Done") { close() } }, trailing: { EmptyView() })
        } else {
            Header(title, leading: { BackButton() }, trailing: { HomeButton() })
        }
    }
    @ViewBuilder private var editingBlock: some View {
        @Bindable var editor = model
        TextField("Title (optional)", text: $editor.value.title).font(.heading).accessibilityIdentifier("noteTitle")
        Toggle("Event has a date", isOn: Binding(get: { model.value.eventDate != nil }, set: { enabled in
            model.value.eventDate = enabled ? journalDate() : nil
            model.value.eventPrecision = enabled ? .exact : .unknown
        })).font(.callout).switchRow()
        if model.value.eventDate != nil {
            LabeledRow("Date") {
                DatePicker("Date", selection: Binding(get: { journalDay(model.value.eventDate ?? journalDate()) }, set: { model.value.eventDate = journalDate($0) }), displayedComponents: .date).labelsHidden()
            }
        }
        TextEditor(text: $editor.value.text)
            .font(.callout).scrollContentBackground(.hidden).focused($writingText)
            .frame(minHeight: 220).fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("noteText")
            .overlay(alignment: .topLeading) {
                if model.value.text.isEmpty {
                    Text("What happened, and how it felt…").font(.callout).foregroundStyle(Color.muted).padding(.top, 8).padding(.leading, 5).allowsHitTesting(false)
                }
            }
            .field()
        Hint("\(model.value.text.unicodeScalars.count) / \(app.limits.maxMemoryChars) characters")
        DisclosureGroup("More", isExpanded: $showMore) {
            VStack(alignment: .leading, spacing: 4) {
                if model.value.eventDate != nil {
                    Picker("Date precision", selection: $editor.value.eventPrecision) {
                        Text("Exact").tag(EventPrecision.exact)
                        Text("Approximate").tag(EventPrecision.approximate)
                    }.pickerStyle(.segmented).padding(.vertical, 8)
                }
                Toggle("Still going on", isOn: $editor.value.isOngoing).switchRow()
                Toggle("Allow AI use", isOn: $editor.value.allowAnalysis).switchRow()
            }.padding(.top, 8)
        }.font(.callout).padding(.top, 8)
        if model.conflict {
            VStack(alignment: .leading, spacing: 10) {
                Text("Stored note changed").font(.heading)
                Button("Reload stored note") { Task { await model.load(app) } }.buttonStyle(.secondary)
                if let stored = model.stored, stored.revision != model.value.baseRevision {
                    Text(stored.text).font(.callout)
                    Button("Keep both") { model.keepMine(both: true) }.buttonStyle(.secondary)
                    Button("Use my text") { model.keepMine() }.buttonStyle(.secondary)
                    Button("Use stored note") { model.useStored() }.buttonStyle(.secondary)
                }
            }.card()
        }
        if model.missing { Button("Save as a new note") { Task { await model.saveAsNew(app) } }.buttonStyle(.secondary) }
    }
    @ViewBuilder private func readingBlock(_ stored: Memory) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Hint(stored.eventDate.map(displayDate) ?? stored.recordedAt.formatted(date: .abbreviated, time: .omitted))
            Spacer()
            Button("Edit") { model.isEditing = true }.buttonStyle(.secondary)
        }
        Text(stored.text).font(.callout).textSelection(.enabled)
        DisclosureGroup("More", isExpanded: $showMore) {
            VStack(alignment: .leading, spacing: 0) {
                LabeledRow("Recorded") { Text(stored.recordedAt.formatted(date: .abbreviated, time: .shortened)).font(.callout) }
                if let date = stored.eventDate {
                    LabeledRow("Event date") { Text(displayDate(date)).font(.callout) }
                    LabeledRow("Precision") { Text(stored.eventPrecision.rawValue.capitalized).font(.callout) }
                }
                LabeledRow("Ongoing") { Text(stored.isOngoing ? "Yes" : "No").font(.callout) }
                LabeledRow("Allow AI use") { Text(stored.allowAnalysis ? "On" : "Off").font(.callout) }
            }.padding(.top, 8)
        }.font(.callout).padding(.top, 8)
    }
    @ViewBuilder private var photosBlock: some View {
        let saved = model.stored?.photos ?? []
        if !saved.isEmpty || !model.pendingPhotos.isEmpty || model.isEditing {
            Heading("Photos")
            ForEach(saved) { photo in
                if let data = model.photoContent[photo.id], let image = UIImage(data: data) {
                    Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 260).clipShape(RoundedRectangle(cornerRadius: 15)).accessibilityLabel("Saved note photo")
                } else { Hint("Photo could not be loaded") }
                if model.isEditing { Button("Remove photo", role: .destructive) { removingPhoto = photo.id }.buttonStyle(.quiet) }
            }
            ForEach(model.pendingPhotos) { photo in
                if let image = UIImage(data: photo.content) { Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 260).clipShape(RoundedRectangle(cornerRadius: 15)) }
                Button("Remove selected photo", role: .destructive) { model.pendingPhotos.removeAll { $0.id == photo.id } }.buttonStyle(.quiet)
            }
            if model.isEditing {
                PhotosPicker(selection: $selectedPhotos, maxSelectionCount: max(1, 5 - saved.count - model.pendingPhotos.count), matching: .images) {
                    Label("Add photos", systemImage: "photo.badge.plus")
                }
                .buttonStyle(.secondary)
                .disabled(model.isAddingPhotos || saved.count + model.pendingPhotos.count >= 5)
                if model.isAddingPhotos { ProgressView("Preparing photos…") }
            }
        }
    }
    private func reload() { Task { await model.load(app) } }
    private func close() {
        guard !model.isSending, !model.isAddingPhotos else { return }
        if model.hasChanges { confirmingClose = true } else { dismiss() }
    }
    private func cancel() {
        if model.stored != nil { model.useStored() } else { close() }
    }
    private func save(close: Bool = false) async {
        writingText = false
        if await model.save(app) {
            if close { dismiss() }
        } else { showingSaveError = true }
    }
}
