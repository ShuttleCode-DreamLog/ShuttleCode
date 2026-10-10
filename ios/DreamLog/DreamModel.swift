import Foundation
import Observation

@MainActor @Observable
final class DreamModel {
    var id: String
    var dream: Dream?
    var draft: Draft?
    var error: String?
    var isEditing: Bool
    var isLoading = false
    var isSending = false
    var missing = false
    var deleted = false
    var conflictReloaded = false
    private let newEntry: Bool
    private var epoch: Int?
    private var writing: Task<Result<Void, StoreError>, Never>?

    init(id: String, newEntry: Bool = false) { self.id = id; self.newEntry = newEntry; isEditing = newEntry }
    private func current(_ app: AppModel) -> Bool { epoch == app.journalEpoch && !app.deleting && app.noticeSeen }
    private func persist(_ value: Draft, app: AppModel) async -> Bool {
        guard current(app) else { return false }
        switch await app.store.saveDraft(value) {
        case .success: return true
        case .failure: error = "Could not save this draft on the phone. Unlock the phone and try again."; return false
        }
    }
    func change(_ app: AppModel, edit: (inout Draft) -> Void) {
        guard var value = draft, !isSending, current(app) else { return }
        edit(&value)
        value.unsent = true; value.updatedAt = .now
        draft = value
        let previous = writing
        writing = Task {
            _ = await previous?.value
            guard self.current(app) else { return .failure(.filesFailed) }
            let result = await app.store.saveDraft(value)
            if case .failure = result { self.error = "Could not save this draft on the phone. Unlock the phone and try again." }
            return result
        }
    }
    private func flush() async -> Bool {
        guard let writing else { return true }
        if case .success = await writing.value { return true }
        return false
    }
    func load(_ app: AppModel) async {
        guard !isLoading, app.noticeSeen, !app.deleting, let client = app.client else { return }
        if let epoch, epoch != app.journalEpoch { return }
        epoch = app.journalEpoch
        isLoading = true
        defer { isLoading = false }
        guard await flush(), current(app) else { return }
        switch await app.store.draft(id) {
        case let .success(value): if let value { draft = value; isEditing = value.unsent }
        case .failure: error = "Could not read this draft. Unlock the phone and try again."; return
        }
        if draft == nil && newEntry && dream == nil {
            draft = Draft(dreamId: id, dreamDate: journalDate())
            if let draft { _ = await persist(draft, app: app) }
            return
        }
        if let draft, draft.baseRevision == 0 && !draft.unconfirmed { isEditing = true; return }
        switch await client.loadDream(id) {
        case let .success(value):
            guard current(app) else { return }
            error = nil
            await receive(value, app: app)
        case let .failure(failure):
            guard current(app) else { return }
            if failure.code == "not_found" {
                if var draft {
                    draft.unconfirmed = false; draft.sentText = nil
                    self.draft = draft
                    missing = draft.baseRevision > 0
                    _ = await persist(draft, app: app)
                } else { missing = true }
            }
            error = failure.message
        }
    }
    private func receive(_ value: Dream, app: AppModel) async {
        dream = value; missing = false
        guard var kept = draft, kept.unsent else { draft = Draft(dream: value); return }
        if kept.unconfirmed {
            let known = kept.baseRevision == value.revision || kept.sentText == value.text
            kept.baseRevision = known ? value.revision : kept.baseRevision
            kept.conflict = !known
            kept.unconfirmed = false; kept.sentText = nil
            kept.source = value.source; kept.permissions = value.permissions
        }
        if kept.matches(value) {
            if case .success = await app.store.deleteDraft(id) { draft = Draft(dream: value); isEditing = false }
            else { error = "Saved on the server, but the local draft could not be removed." }
        } else {
            draft = kept; isEditing = true
            conflictReloaded = kept.conflict
            _ = await persist(kept, app: app)
        }
    }
    func canSave(_ app: AppModel) -> Bool {
        guard let draft else { return false }
        let length = draft.text.unicodeScalars.count
        let withinLimit = length <= app.limits.maxDreamChars || length <= (dream?.text.unicodeScalars.count ?? 0)
        return !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && withinLimit && (draft.title?.unicodeScalars.count ?? 0) <= app.limits.maxTitleChars && !draft.conflict && !missing && !isSending && !isLoading
    }
    func save(_ app: AppModel) async {
        guard !isSending, let client = app.client, current(app) else { return }
        isSending = true
        defer { isSending = false }
        guard await flush() else { return }
        if draft?.unconfirmed == true {
            switch await client.loadDream(id) {
            case let .success(value):
                guard current(app) else { return }
                await receive(value, app: app)
                if draft?.conflict == true || draft?.unsent == false { return }
            case let .failure(failure):
                guard current(app) else { return }
                guard failure.code == "not_found", var kept = draft else { error = failure.message; return }
                kept.unconfirmed = false; kept.sentText = nil; draft = kept
                if kept.baseRevision > 0 { missing = true; error = "This entry is no longer on the server. Save it as a new entry or discard the draft."; return }
            }
        }
        guard var sending = draft, !sending.conflict, !missing else { return }
        let length = sending.text.unicodeScalars.count
        guard !sending.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (length <= app.limits.maxDreamChars || length <= (dream?.text.unicodeScalars.count ?? 0)),
              (sending.title?.unicodeScalars.count ?? 0) <= app.limits.maxTitleChars else { error = "Text or title is empty or exceeds its limit."; return }
        sending.unconfirmed = true; sending.sentText = sending.text
        draft = sending
        guard await persist(sending, app: app) else { return }
        let result = await client.saveDream(id, value: sending.save)
        guard current(app) else { return }
        switch result {
        case let .success(value):
            dream = value
            if case .success = await app.store.deleteDraft(id) {
                draft = Draft(dream: value); isEditing = false; error = nil
            } else { error = "Saved on the server. Retry to clear the local draft." }
        case let .failure(failure):
            var kept = sending
            if !failure.uncertainSave { kept.unconfirmed = false; kept.sentText = nil }
            kept.conflict = failure.code == "revision_conflict"
            conflictReloaded = false; missing = failure.code == "not_found"
            draft = kept
            _ = await persist(kept, app: app)
            error = failure.message
        }
    }
    func keepBoth(_ app: AppModel) {
        guard let dream else { return }
        change(app) { draft in
            draft.text += "\n\n" + dream.text
            draft.baseRevision = dream.revision; draft.conflict = false
        }
        conflictReloaded = false; error = nil
    }
    func useMyText(_ app: AppModel) async {
        guard let dream else { return }
        change(app) { $0.baseRevision = dream.revision; $0.conflict = false }
        conflictReloaded = false
        await save(app)
    }
    func discardChanges(_ app: AppModel) async {
        guard await flush(), current(app), let dream else { return }
        if case .success = await app.store.deleteDraft(id) {
            draft = Draft(dream: dream); isEditing = false; error = nil; conflictReloaded = false
        } else { error = "Could not discard the local changes. Try again." }
    }
    func revert(_ app: AppModel) async {
        guard !isSending, await flush(), current(app) else { return }
        guard draft?.unconfirmed != true else { error = "Check the stored entry before reverting an unconfirmed save."; await load(app); return }
        if dream != nil { await discardChanges(app); return }
        guard case .success = await app.store.deleteDraft(id) else { error = "Could not revert the local draft."; return }
        draft = Draft(dreamId: id, dreamDate: journalDate()); error = nil
    }
    func saveAsNew(_ app: AppModel) async {
        guard await flush(), var kept = draft, current(app) else { return }
        let oldID = id
        kept.dreamId = newID(); kept.baseRevision = 0; kept.source = .text
        kept.conflict = false; kept.unconfirmed = false; kept.sentText = nil
        guard await persist(kept, app: app) else { return }
        guard case .success = await app.store.deleteDraft(oldID) else { error = "Could not remove the old draft. Your text is kept."; return }
        id = kept.dreamId; draft = kept; dream = nil; missing = false
        await save(app)
    }
    func delete(_ app: AppModel) async {
        guard !isSending, current(app), let client = app.client else { return }
        isSending = true
        defer { isSending = false }
        guard await flush() else { return }
        let localOnly = dream == nil && draft?.baseRevision == 0 && draft?.unconfirmed == false
        if !localOnly {
            let result = await client.deleteDream(id)
            guard current(app) else { return }
            if case let .failure(failure) = result, failure.code != "not_found" { error = failure.message; return }
        }
        guard case .success = await app.store.deleteDraft(id) else { error = "Could not erase the local draft. Try again."; return }
        deleted = true
    }
    @discardableResult func close(_ app: AppModel) async -> Bool {
        guard !deleted, !isSending, await flush(), current(app), let draft else { return deleted }
        if draft.baseRevision == 0 && !draft.unconfirmed && draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if case .success = await app.store.deleteDraft(id) { return true }
            error = "Could not remove the empty draft."; return false
        }
        if !draft.unsent { return true }
        guard canSave(app) else { error = "Resolve the entry conflict or text limit before leaving. Your draft is kept."; return false }
        await save(app)
        return self.draft?.unsent == false
    }
}
