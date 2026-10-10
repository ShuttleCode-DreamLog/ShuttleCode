import SwiftUI
import PhotosUI

struct NotesView: View {
    @Environment(AppModel.self) private var app
    @State private var model = NotesModel()
    @State private var path: [String] = []
    @State private var creating: EntryRoute?
    var body: some View {
        NavigationStack(path: $path) {
            List {
                if let error = model.error {
                    Section { Text(error).foregroundStyle(.red); Button("Try again") { Task { await model.load(app) } } }
                }
                if model.items.isEmpty && !model.isLoading {
                    ContentUnavailableView("No life notes", systemImage: "note.text", description: Text("Tap + to record an event or thought from your waking life."))
                }
                ForEach(model.items) { note in
                    NavigationLink(value: note.id) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(note.text.isEmpty ? "Photo note" : note.text).lineLimit(3)
                            HStack {
                                Text(note.eventDate ?? note.recordedAt.formatted(date: .abbreviated, time: .omitted))
                                if note.isOngoing { Text("Ongoing") }
                                if !note.photos.isEmpty { Label("\(note.photos.count)", systemImage: "photo") }
                            }.font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if model.hasMore {
                    Button("Load more") { Task { await model.load(app, more: true) } }.disabled(model.isLoading)
                }
                if model.isLoading { ProgressView() }
            }
            .navigationTitle("Notes")
            .toolbar { Button("New life note", systemImage: "plus") { creating = EntryRoute(id: newID()) } }
            .navigationDestination(for: String.self) { NoteEditorView(id: $0) }
            .sheet(item: $creating, onDismiss: { Task { await model.load(app) } }) { entry in
                NavigationStack { NoteEditorView(id: entry.id, newEntry: true) }
            }
            .task { await model.load(app) }
            .refreshable { await model.load(app) }
            .onChange(of: path) { _, value in if value.isEmpty { Task { await model.load(app) } } }
        }
    }
}

struct NoteEditorView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var model: NoteEditorModel
    @State private var confirmingDelete = false
    @State private var confirmingClose = false
    @State private var showingSaveError = false
    @FocusState private var writingText: Bool
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var removingPhoto: String?
    let newEntry: Bool
    init(id: String, newEntry: Bool = false) {
        _model = State(initialValue: NoteEditorModel(id: id, newEntry: newEntry))
        self.newEntry = newEntry
    }
    var body: some View {
        @Bindable var editor = model
        Form {
            if model.isLoading { ProgressView() }
            if let error = model.error {
                Section {
                    Text(error).foregroundStyle(.red)
                    if !model.isEditing { Button("Try again") { Task { await model.load(app) } } }
                }
            }
            if model.isEditing {
                Section("Life note") {
                    TextEditor(text: $editor.value.text).focused($writingText).frame(minHeight: 220).accessibilityIdentifier("noteText")
                    Text("\(model.value.text.unicodeScalars.count) / \(app.limits.maxMemoryChars) characters").font(.caption).foregroundStyle(.secondary)
                }
                Section("Details") {
                    Toggle("Event has a date", isOn: Binding(get: { model.value.eventDate != nil }, set: { enabled in
                        model.value.eventDate = enabled ? journalDate() : nil
                        model.value.eventPrecision = enabled ? .exact : .unknown
                    }))
                    if model.value.eventDate != nil {
                        DatePicker("Event date", selection: Binding(get: { journalDay(model.value.eventDate ?? journalDate()) }, set: { model.value.eventDate = journalDate($0) }), displayedComponents: .date)
                        Picker("Date precision", selection: $editor.value.eventPrecision) {
                            Text("Exact").tag(EventPrecision.exact)
                            Text("Approximate").tag(EventPrecision.approximate)
                        }
                    }
                    Toggle("Still going on", isOn: $editor.value.isOngoing)
                    Toggle("Allow future AI context", isOn: $editor.value.allowAnalysis)
                }
                if model.conflict {
                    Section("Stored note changed") {
                        Button("Reload stored note") { Task { await model.load(app) } }
                        if let stored = model.stored, stored.revision != model.value.baseRevision {
                            Text(stored.text)
                            Button("Keep both") { model.keepMine(both: true) }
                            Button("Use my text") { model.keepMine() }
                            Button("Use stored note") { model.useStored() }
                        }
                    }
                }
                if model.missing { Button("Save as a new note") { Task { await model.saveAsNew(app) } } }
                Text("Tap Save to store this note. Unsent notes are kept only while this editor is open.")
                    .font(.footnote).foregroundStyle(.secondary)
            } else if let stored = model.stored {
                Section("Life note") { Text(stored.text).textSelection(.enabled) }
                Section("Details") {
                    LabeledContent("Recorded", value: stored.recordedAt.formatted(date: .abbreviated, time: .shortened))
                    if let date = stored.eventDate { LabeledContent("Event date", value: date); LabeledContent("Precision", value: stored.eventPrecision.rawValue) }
                    LabeledContent("Ongoing", value: stored.isOngoing ? "Yes" : "No")
                    LabeledContent("Future AI context", value: stored.allowAnalysis ? "Allowed" : "Off")
                }
            }
            if model.stored != nil { Section { Button("Delete note", role: .destructive) { confirmingDelete = true } } }
            Section("Photos") {
                ForEach(model.stored?.photos ?? []) { photo in
                    if let data = model.photoContent[photo.id], let image = UIImage(data: data) {
                        Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 260).accessibilityLabel("Saved note photo")
                    } else { Text("Photo could not be loaded.") }
                    if model.isEditing { Button("Remove photo", role: .destructive) { removingPhoto = photo.id } }
                }
                ForEach(model.pendingPhotos) { photo in
                    if let image = UIImage(data: photo.content) { Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 260) }
                    Button("Remove selected photo", role: .destructive) { model.pendingPhotos.removeAll { $0.id == photo.id } }
                }
                if model.isEditing {
                    PhotosPicker(selection: $selectedPhotos, maxSelectionCount: max(1, 5 - (model.stored?.photos.count ?? 0) - model.pendingPhotos.count), matching: .images) {
                        Label("Add photos", systemImage: "photo.badge.plus")
                    }.disabled(model.isAddingPhotos || (model.stored?.photos.count ?? 0) + model.pendingPhotos.count >= 5)
                    if model.isAddingPhotos { ProgressView("Preparing photos…") }
                    Text("Up to 5 photos. Tap Save to upload; text is optional for photo notes.").font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .disabled(model.isSending)
        .navigationTitle(newEntry ? "New note" : "Life note")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(model.isSending)
        .toolbar {
            if newEntry {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { if model.hasChanges { confirmingClose = true } else { dismiss() } }.disabled(model.isSending || model.isAddingPhotos)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                if model.isSending { ProgressView() }
                else if model.isEditing { Button("Save") { Task { await save() } }.disabled(!model.canSave(app)).accessibilityIdentifier("saveNote") }
                else if model.stored != nil { Button("Edit") { model.isEditing = true } }
            }
        }
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
    private func save(close: Bool = false) async {
        writingText = false
        if await model.save(app) {
            if close { dismiss() }
        } else { showingSaveError = true }
    }
}
