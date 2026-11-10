import Foundation
import Testing
@testable import DreamLog

extension FoundationTests {
    @Test(arguments: [nil, false, true] as [Bool?])
    func dreamLoadsWithOptionalSummaryCorrectionFlag(_ corrected: Bool?) async throws {
        let (app, identity, defaults, namespace) = try await journalApp()
        defer { _ = identity.delete(); defaults.removePersistentDomain(forName: namespace) }
        let id = newID()
        var payload = try #require(JSONSerialization.jsonObject(with: dreamResponse(journalDream(id: id))) as? [String: Any])
        var dream = try #require(payload["dream"] as? [String: Any])
        var organization: [String: Any] = ["status": "current", "dream_revision": 1, "summary": "An invented summary.", "tags": [], "created_at": 1000]
        if let corrected { organization["summary_corrected"] = corrected }
        dream["organization"] = organization
        payload["dream"] = dream
        enqueue([(200, try JSONSerialization.data(withJSONObject: payload))])
        let model = DreamModel(id: id)
        await model.load(app)
        #expect(model.error == nil)
        #expect(model.dream?.organization?.summary == "An invented summary.")
        await closeJournalApp(app)
    }

    @Test func closingJournalSavesAutomaticallyAndRevertDiscardsChanges() async throws {
        let (app, identity, defaults, namespace) = try await journalApp()
        defer { _ = identity.delete(); defaults.removePersistentDomain(forName: namespace) }
        let id = newID()
        let model = DreamModel(id: id, newEntry: true)
        await model.load(app)
        model.change(app) { $0.text = "An invented dream." }
        #expect(try await app.store.draft(id).get()?.text == "")
        enqueue([(201, try dreamResponse(journalDream(id: id)))])
        #expect(await model.close(app))
        #expect(model.draft?.unsent == false)
        #expect(BackendProtocol.state.withLock { $0.requests.map(\.httpMethod) } == ["PUT"])
        model.isEditing = true
        model.change(app) { $0.text = "Discard this edit." }
        await model.revert(app)
        #expect(model.draft?.text == "An invented dream.")
        #expect(await model.close(app))
        #expect(BackendProtocol.state.withLock { $0.requests.count } == 1)
        await closeJournalApp(app)
    }
    @Test func trailingBlankLinesAreDroppedAndAddingOnlyThemSendsNothing() async throws {
        let (app, identity, defaults, namespace) = try await journalApp()
        defer { _ = identity.delete(); defaults.removePersistentDomain(forName: namespace) }
        let id = newID()
        let model = DreamModel(id: id, newEntry: true)
        await model.load(app)
        model.change(app) { $0.text = "An invented dream.\n\n \n\n" }
        enqueue([(201, try dreamResponse(journalDream(id: id)))])
        #expect(await model.close(app))
        let sent = try #require(lastRequest())
        #expect(sentBody(sent)?["text"] as? String == "An invented dream.")
        model.isEditing = true
        model.change(app) { $0.text += "\n\n\n" }
        #expect(await model.close(app))
        // Only blank lines were added, so nothing is sent and the server schedules no new analysis.
        #expect(BackendProtocol.state.withLock { $0.requests.count } == 1)
        #expect(model.draft?.text == "An invented dream." && model.draft?.unsent == false && !model.isEditing)
        #expect(try await app.store.draft(id).get() == nil)
        await closeJournalApp(app)
    }

    @Test func editorOpenedWithEditStartsEditingOverAStoredSavedDraft() async throws {
        let (app, identity, defaults, namespace) = try await journalApp()
        defer { _ = identity.delete(); defaults.removePersistentDomain(forName: namespace) }
        let id = newID()
        let created = DreamModel(id: id, newEntry: true)
        await created.load(app)
        created.change(app) { $0.text = "An invented dream." }
        enqueue([(201, try dreamResponse(journalDream(id: id)))])
        #expect(await created.close(app))
        // The sheet closes the editor once more as it disappears, which stores the saved dream as a draft with nothing unsent.
        #expect(await created.close(app))
        #expect(try await app.store.draft(id).get()?.unsent == false)
        enqueue([(200, try dreamResponse(journalDream(id: id)))])
        let editor = DreamModel(id: id, editing: true)
        await editor.load(app)
        #expect(editor.isEditing)
        await closeJournalApp(app)
    }

    @Test func storedTrailingBlankLinesStayWhenOnlyTheMoodChanges() async throws {
        let (app, identity, defaults, namespace) = try await journalApp()
        defer { _ = identity.delete(); defaults.removePersistentDomain(forName: namespace) }
        let id = newID()
        let stored = journalDream(id: id, text: "Saved before the trimming.\n\n")
        enqueue([(200, try dreamResponse(stored))])
        let model = DreamModel(id: id)
        await model.load(app)
        model.isEditing = true
        model.change(app) { $0.mood = .calm; $0.text += "\n" }
        enqueue([(200, try dreamResponse(stored))])
        #expect(await model.close(app))
        // The text the server holds is sent back unchanged, so the mood change does not count as a new text revision.
        let sent = try #require(lastRequest())
        #expect(sentBody(sent)?["text"] as? String == "Saved before the trimming.\n\n")
        await closeJournalApp(app)
    }

    func journalDream(id: String, text: String = "An invented dream.", title: String? = nil, revision: Int = 1) -> Dream {
        Dream(id: id, text: text, revision: revision, dreamDate: journalDate(), title: title, mood: nil, source: .text, audioStatus: "none", permissions: Permissions(), tasks: [], createdAt: .now, updatedAt: .now)
    }
    func dreamResponse(_ dream: Dream) throws -> Data {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return try encoder.encode(["dream": dream])
    }
    func journalApp() async throws -> (AppModel, Identity, UserDefaults, String) {
        let config = configuration()
        let namespace = "journal-tests-\(newID())"
        let defaults = try #require(UserDefaults(suiteName: namespace))
        let identity = Identity(service: namespace)
        _ = try identity.create().get()
        defaults.set(noticeVersion, forKey: noticeKey)
        defaults.set(noticeFingerprint, forKey: noticeContentKey)
        enqueue([(200, try response(history: true, zone: TimeZone.current.identifier))])
        let app = AppModel(defaults: defaults, identity: identity, folder: URL.temporaryDirectory.appending(path: namespace), configuration: config)
        await app.start()
        #expect(app.ready && app.noticeSeen)
        BackendProtocol.state.withLock { $0.requests = [] }
        return (app, identity, defaults, namespace)
    }
    func closeJournalApp(_ app: AppModel) async {
        if let client = app.client { await client.cancelAndWait() }
        _ = await app.store.deleteEverything()
    }

    @Test func draftSurvivesReopenAndUpsertKeepsOneRow() async throws {
        let folder = URL.temporaryDirectory.appending(path: "draft-tests-\(newID())")
        let store = LocalStore(folder: folder)
        try await store.open().get()
        var draft = Draft(dreamId: newID(), dreamDate: "2026-10-08")
        draft.text = "A dream 👨‍👩‍👧‍👦 and café."; draft.permissions.history = false
        draft.unconfirmed = true; draft.sentText = draft.text
        try await store.saveDraft(draft).get()
        draft.text += " Kept text."
        try await store.saveDraft(draft).get()
        let reopened = LocalStore(folder: folder)
        try await reopened.open().get()
        let values = try await reopened.drafts().get()
        #expect(values.count == 1 && values[0].text == draft.text)
        #expect(values[0].unconfirmed && values[0].permissions.history == false)
        #expect(values[0].sentText != values[0].text)
        _ = await store.deleteEverything()
        _ = await reopened.deleteEverything()
    }

    @Test func journalJoinsDraftAndServerEntryWithoutDuplicates() {
        let model = JournalModel()
        let id = newID()
        model.items = [JournalItem(id: id, dreamDate: "2026-10-08", revision: 1, audioStatus: "none", preview: "Stored", status: .ready, updatedAt: .now)]
        var draft = Draft(dreamId: id, dreamDate: "2026-10-08")
        draft.text = "Kept edit"; draft.baseRevision = 1
        model.drafts = [draft]
        #expect(model.rows.count == 1)
        #expect(model.rows[0].status == .unsentDraft && model.rows[0].preview == "Kept edit")
    }

    @Test func dreamSaveWritesNullsAndOnlySendsPermissionsAtCreation() throws {
        var draft = Draft(dreamId: newID(), dreamDate: "2026-10-08")
        let first = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(draft.save)) as? [String: Any])
        #expect(first["title"] is NSNull && first["mood"] is NSNull)
        #expect(first["permissions"] != nil)
        draft.baseRevision = 1
        let edit = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(draft.save)) as? [String: Any])
        #expect(edit["permissions"] == nil)
    }

    @Test func textLengthUsesScalarsAndRejectsWhitespace() async throws {
        let (app, identity, defaults, namespace) = try await journalApp()
        defer { _ = identity.delete(); defaults.removePersistentDomain(forName: namespace) }
        let model = DreamModel(id: newID(), newEntry: true)
        await model.load(app)
        model.change(app) { $0.text = "   " }
        #expect(!model.canSave(app))
        app.limits.maxDreamChars = 1
        model.change(app) { $0.text = "e\u{301}" }
        #expect(!model.canSave(app))
        model.change(app) { $0.text = "é" }
        #expect(model.canSave(app))
        await model.close(app)
        await closeJournalApp(app)
    }

    @Test func offlineSaveKeepsDraftAndUncertainSaveReadsBeforeRetry() async throws {
        let (app, identity, defaults, namespace) = try await journalApp()
        defer { _ = identity.delete(); defaults.removePersistentDomain(forName: namespace) }
        let id = newID()
        let model = DreamModel(id: id, newEntry: true)
        await model.load(app)
        model.change(app) { $0.text = "An invented dream." }
        enqueue([(500, Data("{\"error\":\"internal\",\"message\":\"Try again\"}".utf8))])
        await model.save(app)
        #expect(try await app.store.draft(id).get()?.unconfirmed == true)
        #expect(model.draft?.text == "An invented dream.")
        enqueue([(200, try dreamResponse(journalDream(id: id)))])
        await model.save(app)
        #expect(BackendProtocol.state.withLock { $0.requests.map(\.httpMethod) } == ["PUT", "GET"])
        #expect(try await app.store.draft(id).get() == nil)
        #expect(model.dream?.text == "An invented dream.")
        await closeJournalApp(app)
    }

    @Test func unconfirmedMissingEntryDoesNotAutomaticallySaveOnLoad() async throws {
        let (app, identity, defaults, namespace) = try await journalApp()
        defer { _ = identity.delete(); defaults.removePersistentDomain(forName: namespace) }
        var draft = Draft(dreamId: newID(), dreamDate: "2026-10-08")
        draft.text = "Kept invented text"; draft.unconfirmed = true; draft.sentText = draft.text
        try await app.store.saveDraft(draft).get()
        enqueue([(404, Data("{\"error\":\"not_found\",\"message\":\"Missing\"}".utf8))])
        let model = DreamModel(id: draft.dreamId)
        await model.load(app)
        #expect(model.draft?.unconfirmed == false && model.draft?.text == draft.text)
        #expect(BackendProtocol.state.withLock { $0.requests.map(\.httpMethod) } == ["GET"])
        await closeJournalApp(app)
    }

    @Test func conflictKeepsAttemptedTextAndMergesOnlyAfterReload() async throws {
        let (app, identity, defaults, namespace) = try await journalApp()
        defer { _ = identity.delete(); defaults.removePersistentDomain(forName: namespace) }
        let id = newID()
        enqueue([(200, try dreamResponse(journalDream(id: id)))])
        let model = DreamModel(id: id)
        await model.load(app)
        model.isEditing = true
        model.change(app) { $0.text = "My kept text" }
        enqueue([(409, Data("{\"error\":\"revision_conflict\",\"message\":\"Reload\",\"current_revision\":2}".utf8))])
        await model.save(app)
        #expect(model.draft?.conflict == true && model.draft?.text == "My kept text")
        enqueue([(200, try dreamResponse(journalDream(id: id, text: "New stored text", revision: 2)))])
        await model.load(app)
        #expect(model.conflictReloaded)
        model.keepBoth(app)
        #expect(model.draft?.text == "My kept text\n\nNew stored text")
        #expect(model.draft?.baseRevision == 2 && model.draft?.conflict == false)
        await model.close(app)
        await closeJournalApp(app)
    }

    @Test func deleteFailureKeepsLocalTextAndRepeatedDeletionIsSafe() async throws {
        let (app, identity, defaults, namespace) = try await journalApp()
        defer { _ = identity.delete(); defaults.removePersistentDomain(forName: namespace) }
        let id = newID()
        enqueue([(200, try dreamResponse(journalDream(id: id)))])
        let model = DreamModel(id: id)
        await model.load(app)
        model.change(app) { $0.text = "Unsent changes" }
        enqueue([(500, Data())])
        await model.delete(app)
        let retained = try await app.store.draft(id).get()
        #expect(!model.deleted && retained?.text == "Unsent changes")
        enqueue([(404, Data("{\"error\":\"not_found\",\"message\":\"Already deleted\"}".utf8))])
        await model.delete(app)
        let removed = try await app.store.draft(id).get()
        #expect(model.deleted && removed == nil)
        await closeJournalApp(app)
    }
}

extension FoundationTests {
    @Test func manualTagsSurviveDraftReopenAndEncodeAnExplicitEmptySelection() async throws {
        let folder = URL.temporaryDirectory.appending(path: "tag-draft-\(newID())")
        let store = LocalStore(folder: folder)
        try await store.open().get()
        var draft = Draft(dreamId: newID(), dreamDate: journalDate())
        draft.text = "An invented tagged dream."
        draft.tagIds = [newID(), newID()]
        try await store.saveDraft(draft).get()
        let reopened = LocalStore(folder: folder)
        try await reopened.open().get()
        let saved = try #require(try await reopened.draft(draft.dreamId).get())
        #expect(saved.tagIds == draft.tagIds)
        let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(saved.save)) as? [String: Any])
        #expect(encoded["tag_ids"] as? [String] == draft.tagIds)
        draft.tagIds = []
        let cleared = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(draft.save)) as? [String: Any])
        #expect(cleared["tag_ids"] as? [String] == [])
        draft.tagIds = nil
        let legacy = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(draft.save)) as? [String: Any])
        #expect(legacy["tag_ids"] == nil)
        try await reopened.deleteEverything().get()
        try await store.deleteEverything().get()
    }

    @Test func tagLibraryUsesServerIDsAndPreservesNamesAfterFailedRename() async throws {
        let (app, identity, defaults, namespace) = try await journalApp()
        defer { _ = identity.delete(); defaults.removePersistentDomain(forName: namespace) }
        let library = TagLibraryModel()
        let id = newID()
        enqueue([(200, Data("{\"tags\":[]}".utf8))])
        await library.load(app)
        #expect(library.loaded && library.tags.isEmpty)
        enqueue([(201, Data("{\"tag\":{\"id\":\"\(id)\",\"text\":\"Home\",\"color\":\"sage\"}}".utf8))])
        let tag = try #require(await library.create(app, text: "Home"))
        #expect(library.tags.map(\.id) == [id])
        let request = try #require(lastRequest())
        #expect(request.url?.path() == "/v1/tag-library" && request.httpMethod == "POST")
        #expect(sentBody(request)?["text"] as? String == "Home")
        enqueue([(409, Data("{\"error\":\"duplicate_tag\",\"message\":\"Already exists\"}".utf8))])
        await library.rename(app, tag: tag, text: "Work")
        #expect(library.tags.first?.text == "Home" && library.error != nil)
        enqueue([(204, Data())])
        #expect(await library.delete(app, tag: tag))
        #expect(library.tags.isEmpty)
        await closeJournalApp(app)
    }
}
