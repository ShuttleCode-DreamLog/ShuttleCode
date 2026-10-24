import SwiftUI

// The prototype's capture screen: the text, then date and mood; ✓ saves and closes. The title lives in the header: the AI names
// the dream with its summary and tags unless the user names it first. Voice capture is left out until the backend has it.
struct DreamEditorView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: DreamModel
    @State private var confirmingDelete = false
    @State private var confirmingDiscard = false
    @State private var renaming = false
    @State private var titleDraft = ""
    let newEntry: Bool
    let presented: Bool

    // `presented` is the editor opened over a dream's screen: it starts editing and always offers Done.
    init(id: String, newEntry: Bool = false, presented: Bool = false, appending: String? = nil) {
        _model = State(initialValue: DreamModel(id: id, newEntry: newEntry, editing: presented, appending: appending))
        self.newEntry = newEntry
        self.presented = presented
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 13) {
                if model.isLoading { ProgressView("Loading entry…") }
                if let error = model.error { ErrorCard(error) }
                if let draft = model.draft {
                    if model.isEditing { capture(draft) }
                    else if let dream = model.dream {
                        Hint([displayDate(dream.dreamDate), dream.mood.map { $0.rawValue.capitalized }].compactMap(\.self).joined(separator: " · "))
                        Text(dream.text).font(.callout).textSelection(.enabled)
                    }
                } else if !model.isLoading {
                    Button("Try again") { Task { await model.load(app) } }.buttonStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
        .dreamPage()
        .page(header, aboveBar: false)
        .disabled(model.isSending)
        .alert("Dream title", isPresented: $renaming) {
            TextField("Dream title", text: $titleDraft)
            Button("Save") { let value = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines); model.change(app) { $0.title = value.isEmpty ? nil : value } }
            Button("Cancel", role: .cancel) {}
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

    private var title: String { model.draft?.title?.isEmpty == false ? model.draft!.title! : newEntry ? "New dream" : "Dream" }
    @ViewBuilder private var header: some View {
        if model.isEditing {
            Header(title, onTitle: { titleDraft = model.draft?.title ?? ""; renaming = true }) {
                BackButton { Task { if await model.close(app) { dismiss() } } }
            } trailing: {
                if model.isSending { ProgressView() } else {
                    Button("Revert") { confirmingDiscard = true }.buttonStyle(.quiet).accessibilityIdentifier("revertJournal")
                    // Over a dream's screen, Delete Dream stays on that screen (EGMUIUX S03).
                    if !presented, let draft = model.draft {
                        Button { confirmingDelete = true } label: { Image(systemName: "trash").font(.system(size: 20)).foregroundStyle(Color.danger) }
                            .buttonStyle(.plain)
                            .accessibilityLabel(draft.baseRevision == 0 && !draft.unconfirmed && model.dream == nil ? "Discard draft" : "Delete journal entry")
                    }
                    Button { Task { if await model.close(app) { dismiss() } } } label: {
                        Image(systemName: "checkmark").font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
                            .frame(width: 36, height: 36).background(Color.sage, in: Circle())
                    }
                    .buttonStyle(.plain).accessibilityLabel("Done")
                }
            }
        } else {
            Header(title) {
                if newEntry || presented { BackButton(label: "Done") { dismiss() } } else { BackButton() }
            } trailing: {
                if model.dream != nil { Button("Edit") { model.isEditing = true }.buttonStyle(.quiet) }
            }
        }
    }

    @ViewBuilder private func capture(_ draft: Draft) -> some View {
        Eyebrow("Capture before it fades")
        Text("What do you remember?").font(.display)
        TextEditor(text: Binding(get: { model.draft?.text ?? "" }, set: { value in model.change(app) { $0.text = value } }))
            .font(.callout).scrollContentBackground(.hidden)
            .frame(minHeight: 240).fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel("Journal text")
            .accessibilityIdentifier("journalText")
            .overlay(alignment: .topLeading) {
                if draft.text.isEmpty {
                    Text("A place, a feeling, a tiny detail…").font(.callout).foregroundStyle(Color.muted).padding(.top, 8).padding(.leading, 5).allowsHitTesting(false)
                }
            }
            .field()
        Hint("\(draft.text.unicodeScalars.count) / \(app.limits.maxDreamChars) characters")
        LabeledRow("Date") {
            DatePicker("Date", selection: Binding(get: { journalDay(model.draft?.dreamDate ?? journalDate()) }, set: { value in model.change(app) { $0.dreamDate = journalDate(value) } }), displayedComponents: .date)
                .labelsHidden()
        }
        LabeledRow("Mood") {
            Picker("Mood", selection: Binding(get: { model.draft?.mood }, set: { value in model.change(app) { $0.mood = value } })) {
                Text("Not specified").tag(Mood?.none)
                ForEach(Mood.allCases.filter { $0 != .unknown }, id: \.self) { mood in Text(mood.rawValue.capitalized).tag(Optional(mood)) }
            }.labelsHidden()
        }
        if draft.unconfirmed { Hint("Not confirmed by the server yet") }
        if draft.conflict {
            VStack(alignment: .leading, spacing: 10) {
                Text("The stored entry changed").font(.heading)
                Button("Reload stored version") { Task { await model.load(app) } }.buttonStyle(.secondary)
                if model.conflictReloaded, let dream = model.dream {
                    Hint("Stored text")
                    Text(dream.text).font(.callout).textSelection(.enabled)
                    Button("Keep both") { model.keepBoth(app) }.buttonStyle(.secondary)
                    Button("Use my text") { Task { await model.useMyText(app) } }.buttonStyle(.secondary)
                    Button("Use the stored text", role: .destructive) { confirmingDiscard = true }.buttonStyle(.secondary)
                }
            }.card()
        } else if model.missing {
            Button("Save as a new journal entry") { Task { await model.saveAsNew(app) } }.buttonStyle(.secondary)
        }
    }
}
