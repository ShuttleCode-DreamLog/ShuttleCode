import Foundation
import Testing
@testable import DreamLog

extension FoundationTests {
    @Test func newNoteCanSaveBeforeInitialViewLoad() async throws {
        let (app, identity, defaults, namespace) = try await journalApp()
        defer { _ = identity.delete(); defaults.removePersistentDomain(forName: namespace) }
        let id = newID()
        let model = NoteEditorModel(id: id, newEntry: true)
        model.value.text = "Saved before the view task."
        enqueue([(201, try memoryResponse(id: id, text: model.value.text))])
        #expect(await model.save(app))
        #expect(model.stored?.text == "Saved before the view task.")
        #expect(!model.hasChanges && !model.isEditing)
        await closeJournalApp(app)
    }
    @Test func unavailableJournalRejectsSaveWithFeedbackAndKeepsInput() async throws {
        let (app, identity, defaults, namespace) = try await journalApp()
        defer { _ = identity.delete(); defaults.removePersistentDomain(forName: namespace) }
        let model = NoteEditorModel(id: newID(), newEntry: true)
        model.value.text = "Keep this unsent note."
        app.noticeSeen = false
        #expect(await model.save(app) == false)
        #expect(model.error != nil && model.value.text == "Keep this unsent note.")
        #expect(BackendProtocol.state.withLock { $0.requests.isEmpty })
        await closeJournalApp(app)
    }
    @Test func photoOnlyNoteKeepsFailedUploadAndRetriesTheSameID() async throws {
        let (app, identity, defaults, namespace) = try await journalApp()
        defer { _ = identity.delete(); defaults.removePersistentDomain(forName: namespace) }
        let id = newID(), photoID = newID()
        let model = NoteEditorModel(id: id, newEntry: true)
        await model.load(app)
        model.pendingPhotos = [PendingPhoto(id: photoID, content: Data([1,2,3]))]
        #expect(model.canSave(app))
        enqueue([(201, try memoryResponse(id: id, text: "")), (500, Data())])
        await model.save(app)
        #expect(model.stored?.id == id && model.pendingPhotos.first?.id == photoID)
        #expect(model.isEditing && model.error != nil)
        let photo = Data("{\"photo\":{\"id\":\"\(photoID)\",\"content_type\":\"image/jpeg\",\"byte_count\":3,\"created_at\":1}}".utf8)
        enqueue([(200, try memoryResponse(id: id, text: "")), (201, photo)])
        await model.save(app)
        #expect(model.pendingPhotos.isEmpty && model.stored?.photos.first?.id == photoID)
        let paths = BackendProtocol.state.withLock { $0.requests.map { $0.url?.path } }
        #expect(paths == ["/v1/memories/\(id)", "/v1/memories/\(id)/photos/\(photoID)", "/v1/memories/\(id)", "/v1/memories/\(id)/photos/\(photoID)"])
        await closeJournalApp(app)
    }
    func memoryResponse(id: String, text: String = "Sample life note.", revision: Int = 1) throws -> Data {
        let memory = Memory(id: id, text: text, recordedAt: .now, eventPrecision: .unknown, isOngoing: false, allowAnalysis: true, revision: revision, updatedAt: .now)
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return try encoder.encode(["memory": memory])
    }
    @Test func noteSaveEncodesExplicitNullDate() throws {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let values = try #require(JSONSerialization.jsonObject(with: encoder.encode(MemorySave())) as? [String: Any])
        #expect(values["event_date"] is NSNull)
        #expect(values["event_precision"] as? String == "unknown")
        #expect(values["base_revision"] as? Int == 0)
    }
    @Test func noteFailureRetainsInputAndConflictReloadKeepsBoth() async throws {
        let (app, identity, defaults, namespace) = try await journalApp()
        defer { _ = identity.delete(); defaults.removePersistentDomain(forName: namespace) }
        let id = newID()
        let model = NoteEditorModel(id: id, newEntry: true)
        await model.load(app)
        #expect(BackendProtocol.state.withLock { $0.requests.isEmpty })
        model.value.text = "My kept text."
        enqueue([(500, Data())])
        await model.save(app)
        #expect(model.value.text == "My kept text." && model.stored == nil)
        enqueue([(409, Data("{\"error\":\"revision_conflict\",\"message\":\"Reload\",\"current_revision\":2}".utf8))])
        await model.save(app)
        #expect(model.conflict)
        enqueue([(200, try memoryResponse(id: id, text: "Stored text.", revision: 2))])
        await model.load(app)
        #expect(model.value.text == "My kept text.")
        model.keepMine(both: true)
        #expect(model.value.text == "My kept text.\n\nStored text.")
        #expect(model.value.baseRevision == 2 && !model.conflict)
        await closeJournalApp(app)
    }
    @Test func noteDeletionFailureKeepsStoredNote() async throws {
        let (app, identity, defaults, namespace) = try await journalApp()
        defer { _ = identity.delete(); defaults.removePersistentDomain(forName: namespace) }
        let id = newID()
        enqueue([(200, try memoryResponse(id: id))])
        let model = NoteEditorModel(id: id)
        await model.load(app)
        enqueue([(500, Data())])
        await model.delete(app)
        #expect(!model.deleted && model.stored?.text == "Sample life note.")
        enqueue([(404, Data("{\"error\":\"not_found\",\"message\":\"Gone\"}".utf8))])
        await model.delete(app)
        #expect(model.deleted)
        await closeJournalApp(app)
    }
    @Test func profileRetainsFailedEditsAndPreservesCustomKeys() async throws {
        let (app, identity, defaults, namespace) = try await journalApp()
        defer { _ = identity.delete(); defaults.removePersistentDomain(forName: namespace) }
        enqueue([(200, Data("{\"profile\":{\"fields\":{\"favorite_color\":\"blue\"},\"revision\":1,\"updated_at\":1}}".utf8))])
        let model = ProfileModel()
        await model.load(app)
        #expect(model.fields["favorite_color"] == "blue")
        model.fields["name"] = "Sample Person"
        model.fields["age"] = "21"
        enqueue([(409, Data("{\"error\":\"revision_conflict\",\"message\":\"Reload\"}".utf8))])
        await model.save(app)
        #expect(model.conflict && model.fields["name"] == "Sample Person")
        #expect(!app.savingSettings)
        let request = try #require(BackendProtocol.state.withLock { $0.requests.last })
        #expect(request.httpMethod == "PUT")
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let requestBody = try encoder.encode(ProfileSave(baseRevision: 1, fields: model.fields))
        let body = try #require(JSONSerialization.jsonObject(with: requestBody) as? [String: Any])
        let fields = try #require(body["fields"] as? [String: String])
        #expect(fields["favorite_color"] == "blue" && fields["age"] == "21")
        await closeJournalApp(app)
    }
}
