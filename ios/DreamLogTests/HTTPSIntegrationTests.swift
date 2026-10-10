import Foundation
import Testing
import UIKit
@testable import DreamLog

@Suite(.enabled(if: ProcessInfo.processInfo.environment["DREAMLOG_HTTPS_SMOKE"] == "1")) @MainActor
struct HTTPSIntegrationTests {
    @Test func localAppLifecycleOverRealHTTPS() async throws {
        let namespace = "https-integration-\(newID())"
        let defaults = try #require(UserDefaults(suiteName: namespace))
        let identity = Identity(service: namespace)
        defer { _ = identity.delete(); defaults.removePersistentDomain(forName: namespace) }
        let model = AppModel(defaults: defaults, identity: identity, folder: URL.temporaryDirectory.appending(path: namespace))
        await model.start()
        #expect(model.ready && !model.noticeSeen && model.me == nil)
        await model.acknowledgeNotice()
        #expect(model.me?.timezone == TimeZone.current.identifier)
        #expect(model.me?.useHistory == true)
        await model.saveHistory(false)
        #expect(model.me?.useHistory == false)
        let id = newID()
        let editor = DreamModel(id: id, newEntry: true)
        await editor.load(model)
        editor.change(model) { $0.title = "Lake"; $0.text = "An invented text journal by a blue lake." }
        #expect(await editor.close(model))
        #expect(editor.dream?.text == "An invented text journal by a blue lake.")
        #expect(try await model.store.draft(id).get() == nil)
        let journal = JournalModel()
        await journal.load(model)
        #expect(journal.rows.contains { $0.id == id })
        let reopened = DreamModel(id: id)
        await reopened.load(model)
        #expect(reopened.dream?.title == "Lake")
        reopened.isEditing = true
        reopened.change(model) { $0.text += " A second scene." }
        #expect(await reopened.close(model))
        #expect(reopened.dream?.revision == 2)
        await reopened.delete(model)
        await journal.load(model)
        #expect(reopened.deleted && !journal.rows.contains { $0.id == id })
        let noteID = newID()
        let note = NoteEditorModel(id: noteID, newEntry: true)
        await note.load(model)
        note.value.text = ""
        let photo = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20)).image { context in
            UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        }
        let photoBytes = try #require(photo.jpegData(compressionQuality: 0.8))
        let photoID = newID()
        note.pendingPhotos = [PendingPhoto(id: photoID, content: photoBytes)]
        await note.save(model)
        #expect(note.stored?.revision == 1)
        #expect(note.stored?.photos.first?.id == photoID && note.pendingPhotos.isEmpty)
        let notes = NotesModel()
        await notes.load(model)
        #expect(notes.items.contains { $0.id == noteID })
        let readNote = NoteEditorModel(id: noteID)
        await readNote.load(model)
        #expect(readNote.stored?.text == note.value.text)
        #expect(readNote.photoContent[photoID] == photoBytes)
        await readNote.deletePhoto(photoID, app: model)
        #expect(readNote.stored?.photos.isEmpty == true)
        readNote.isEditing = true
        readNote.value.text += " Updated."
        await readNote.save(model)
        #expect(readNote.stored?.revision == 2)
        await readNote.delete(model)
        await notes.load(model)
        #expect(readNote.deleted && !notes.items.contains { $0.id == noteID })
        let profile = ProfileModel()
        await profile.load(model)
        profile.fields = ["name": "Sample Person", "age": "21", "favorite_color": "blue"]
        await profile.save(model)
        #expect(profile.stored?.fields["name"] == "Sample Person")
        let readProfile = ProfileModel()
        await readProfile.load(model)
        #expect(readProfile.fields["favorite_color"] == "blue")
        readProfile.fields.removeValue(forKey: "age")
        await readProfile.save(model)
        #expect(readProfile.stored?.fields["age"] == nil)
        await model.deleteJournal()
        #expect(model.ready && !model.noticeSeen && model.me == nil && !model.deleting)
        if let client = model.client { await client.cancelAndWait() }
        _ = await model.store.deleteEverything()
    }
}
