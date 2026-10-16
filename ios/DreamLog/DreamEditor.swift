import SwiftUI

struct DreamEditorView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: DreamModel
    @State private var confirmingDelete = false
    @State private var confirmingDiscard = false
    let newEntry: Bool
    let presented: Bool

    // `presented` is the editor opened over a dream's screen: it starts editing and always offers Done.
    init(id: String, newEntry: Bool = false, presented: Bool = false) {
        _model = State(initialValue: DreamModel(id: id, newEntry: newEntry, editing: presented))
        self.newEntry = newEntry
        self.presented = presented
    }
    var body: some View {
        Form {
            if model.isLoading { ProgressView("Loading entry…") }
            if let error = model.error { Section { Text(error).foregroundStyle(.red) } }
            if let draft = model.draft {
                if model.isEditing {
                    Section("Journal entry") {
                        TextField("Title (optional)", text: Binding(get: { model.draft?.title ?? "" }, set: { value in model.change(app) { $0.title = value.isEmpty ? nil : value } }))
                            .accessibilityIdentifier("journalTitle")
                        DatePicker("Date", selection: Binding(get: { journalDay(model.draft?.dreamDate ?? journalDate()) }, set: { value in model.change(app) { $0.dreamDate = journalDate(value) } }), displayedComponents: .date)
                        Picker("Mood", selection: Binding(get: { model.draft?.mood }, set: { value in model.change(app) { $0.mood = value } })) {
                            Text("Not specified").tag(Mood?.none)
                            ForEach(Mood.allCases.filter { $0 != .unknown }, id: \.self) { mood in
                                Text(mood.rawValue.capitalized).tag(Optional(mood))
                            }
                        }
                        TextEditor(text: Binding(get: { model.draft?.text ?? "" }, set: { value in model.change(app) { $0.text = value } }))
                            .frame(minHeight: 240)
                            .accessibilityLabel("Journal text")
                            .accessibilityIdentifier("journalText")
                        Text("\(draft.text.unicodeScalars.count) / \(app.limits.maxDreamChars) characters")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Section {
                        Text("Changes are saved automatically when you leave this editor. Revert discards your changes.")
                            .font(.footnote).foregroundStyle(.secondary)
                        if draft.unconfirmed { Text("Not confirmed by the server yet. This is checked when the entry is next loaded or sent.") }
                    }
                    if draft.conflict {
                        Section("The stored entry changed") {
                            Button("Reload stored version") { Task { await model.load(app) } }
                            if model.conflictReloaded, let dream = model.dream {
                                Text("Stored text").font(.headline)
                                Text(dream.text).textSelection(.enabled)
                                Button("Keep both") { model.keepBoth(app) }
                                Button("Use my text") { Task { await model.useMyText(app) } }
                                Button("Use the stored text", role: .destructive) { confirmingDiscard = true }
                            }
                        }
                    } else if model.missing {
                        Section {
                            Button("Save as a new journal entry") { Task { await model.saveAsNew(app) } }
                        }
                    }
                } else if let dream = model.dream {
                    Section {
                        LabeledContent("Date", value: dream.dreamDate)
                        if let mood = dream.mood { LabeledContent("Mood", value: mood.rawValue.capitalized) }
                    }
                    Section("Journal text") { Text(dream.text).textSelection(.enabled) }
                }
                // Over a dream's screen, Delete Dream stays on that screen (EGMUIUX S03).
                if !presented {
                    Section {
                        Button(draft.baseRevision == 0 && !draft.unconfirmed && model.dream == nil ? "Discard draft" : "Delete journal entry", role: .destructive) { confirmingDelete = true }
                    }
                }
            } else if !model.isLoading {
                Button("Try again") { Task { await model.load(app) } }
            }
        }
        .disabled(model.isSending)
        .navigationTitle(model.draft?.title?.isEmpty == false ? model.draft!.title! : newEntry ? "New dream" : "Dream Editor")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(model.isEditing || model.isSending)
        .toolbar {
            if newEntry || presented || model.isEditing {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { Task { if await model.close(app) { dismiss() } } }.disabled(model.isSending)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                if model.isSending { ProgressView() }
                else if model.isEditing {
                    Button("Revert") { confirmingDiscard = true }.accessibilityIdentifier("revertJournal")
                } else if model.dream != nil { Button("Edit") { model.isEditing = true } }
            }
        }
        .confirmationDialog("Delete this journal entry and any draft on this phone? This cannot be undone.", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete entry", role: .destructive) { Task { await model.delete(app); if model.deleted { dismiss() } } }
        }
        .confirmationDialog("Revert changes to this journal entry?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
            Button("Revert changes", role: .destructive) { Task { await model.revert(app) } }
        }
        // Over a dream's screen only Done closes the editor, so its save finishes before that screen reads the dream again.
        .interactiveDismissDisabled(presented || model.isSending)
        .task { app.editing.insert(model.id); await model.load(app) }
        .onDisappear { Task { await model.close(app); app.editing.remove(model.id) } }
        .onChange(of: scenePhase) { _, phase in if phase != .active { Task { await model.close(app) } } }
    }
}
