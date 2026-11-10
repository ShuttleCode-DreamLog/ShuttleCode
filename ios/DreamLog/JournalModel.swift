import Foundation
import Observation

@MainActor @Observable
final class JournalModel {
    var items: [JournalItem] = []
    var drafts: [Draft] = []
    var filter = JournalFilter()
    var hasMore = false
    var ranked = false
    var error: String?
    var isLoading = false
    var rows: [JournalRow] {
        let draftByID = Dictionary(uniqueKeysWithValues: drafts.map { ($0.dreamId, $0) })
        let itemIDs = Set(items.map(\.id))
        let local = drafts.filter { !itemIDs.contains($0.dreamId) && ($0.baseRevision == 0 || $0.unsent) }
            .map { JournalRow(id: $0.dreamId, draft: $0) }
        return local + items.map { JournalRow(id: $0.id, item: $0, draft: draftByID[$0.id]) }
    }
    func load(_ app: AppModel, more: Bool = false) async {
        guard app.noticeSeen, !app.deleting, !isLoading, let client = app.client else { return }
        isLoading = true
        let epoch = app.journalEpoch
        // Paint local drafts before the network round-trip so returning to Journal is not a blank wait.
        switch await app.store.drafts() {
        case let .success(value): drafts = value
        case .failure:
            error = "Could not read your local drafts. Unlock the phone and try again."
            isLoading = false
            return
        }
        guard epoch == app.journalEpoch, !app.deleting else { isLoading = false; return }
        let result = await client.loadJournal(filter: filter, offset: more ? items.count : 0)
        guard epoch == app.journalEpoch, !app.deleting else { isLoading = false; return }
        switch result {
        case let .success(page):
            let existing = Set(items.map(\.id))
            items = more ? items + page.items.filter { !existing.contains($0.id) } : page.items
            hasMore = page.hasMore; ranked = page.ranked ?? false; error = nil
        case let .failure(failure):
            if !more { items = [] }
            hasMore = false; error = failure.message
        }
        isLoading = false
        // Story map v2 still resends waiting drafts on every journal load, including when the connection returns.
        // The list is shown first; queued uploads must not delay browsing, then one refresh picks up what was sent.
        if !more, await sendQueued(app), epoch == app.journalEpoch, !app.deleting {
            await load(app)
        }
    }
    // Each waiting draft uses the dream's own save logic, one at a time. Returns whether any draft reached the server.
    private func sendQueued(_ app: AppModel) async -> Bool {
        guard case let .success(stored) = await app.store.drafts() else { return false }
        var sent = false
        for draft in stored where draft.unsent && !draft.conflict && !app.editing.contains(draft.dreamId) {
            let dream = DreamModel(id: draft.dreamId)
            await dream.load(app)
            guard dream.draft?.unsent == true, dream.canSave(app) else { continue }
            await dream.save(app)
            // A draft that is still unsent means the server is out of reach; the others wait for the next load.
            if dream.draft?.unsent == true { break }
            sent = true
        }
        return sent
    }
}
