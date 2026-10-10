import Foundation
import Observation

@MainActor @Observable
final class JournalModel {
    var items: [JournalItem] = []
    var drafts: [Draft] = []
    var filter = JournalFilter()
    var hasMore = false
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
        defer { isLoading = false }
        let epoch = app.journalEpoch
        async let local = app.store.drafts()
        let result = await client.loadJournal(filter: filter, offset: more ? items.count : 0)
        let localResult = await local
        guard epoch == app.journalEpoch, !app.deleting else { return }
        switch localResult {
        case let .success(value): drafts = value
        case .failure: error = "Could not read your local drafts. Unlock the phone and try again."; return
        }
        switch result {
        case let .success(page):
            let existing = Set(items.map(\.id))
            items = more ? items + page.items.filter { !existing.contains($0.id) } : page.items
            hasMore = page.hasMore; error = nil
        case let .failure(failure):
            if !more { items = [] }
            hasMore = false; error = failure.message
        }
    }
}
