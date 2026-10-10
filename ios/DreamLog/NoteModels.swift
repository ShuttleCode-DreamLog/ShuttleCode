import Foundation
import Observation
import SwiftUI
import PhotosUI
import UIKit

nonisolated struct NotePhoto: Codable, Identifiable {
    var id: String
    var contentType: String
    var byteCount: Int
    var createdAt: Date
}
nonisolated struct PhotoResponse: Decodable { var photo: NotePhoto }
nonisolated struct PendingPhoto: Identifiable { let id: String; let content: Data }

nonisolated enum EventPrecision: String, Codable, CaseIterable { case exact, approximate, unknown }

nonisolated struct Memory: Codable, Identifiable {
    var id: String
    var text: String
    var recordedAt: Date
    var eventDate: String?
    var eventPrecision: EventPrecision
    var isOngoing: Bool
    var allowAnalysis: Bool
    var checkinId: String?
    var revision: Int
    var updatedAt: Date
    var photos: [NotePhoto] = []
}

nonisolated struct MemoryPage: Decodable { var items: [Memory]; var hasMore: Bool }
nonisolated struct MemoryResponse: Decodable { var memory: Memory }
nonisolated struct MemorySave: Encodable {
    var baseRevision: Int = 0
    var text = ""
    var eventDate: String?
    var eventPrecision: EventPrecision = .unknown
    var isOngoing = false
    var allowAnalysis = true
    enum CodingKeys: String, CodingKey { case baseRevision, text, eventDate, eventPrecision, isOngoing, allowAnalysis }
    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(baseRevision, forKey: .baseRevision)
        try values.encode(text, forKey: .text)
        try values.encode(eventDate, forKey: .eventDate)
        try values.encode(eventPrecision, forKey: .eventPrecision)
        try values.encode(isOngoing, forKey: .isOngoing)
        try values.encode(allowAnalysis, forKey: .allowAnalysis)
    }
    init() {}
    init(_ memory: Memory) {
        baseRevision = memory.revision; text = memory.text; eventDate = memory.eventDate
        eventPrecision = memory.eventPrecision; isOngoing = memory.isOngoing; allowAnalysis = memory.allowAnalysis
    }
}

@MainActor @Observable
final class NotesModel {
    var items: [Memory] = []
    var hasMore = false
    var isLoading = false
    var error: String?
    func load(_ app: AppModel, more: Bool = false) async {
        guard app.noticeSeen, !app.deleting, !isLoading, let client = app.client else { return }
        isLoading = true
        defer { isLoading = false }
        let epoch = app.journalEpoch
        let result = await client.loadMemories(offset: more ? items.count : 0)
        guard epoch == app.journalEpoch, !app.deleting else { return }
        switch result {
        case let .success(page):
            let ids = Set(items.map(\.id))
            items = more ? items + page.items.filter { !ids.contains($0.id) } : page.items
            hasMore = page.hasMore; error = nil
        case let .failure(failure): error = failure.message
        }
    }
}

@MainActor @Observable
final class NoteEditorModel {
    var id: String
    var stored: Memory?
    var value = MemorySave()
    var isEditing: Bool
    var isLoading = false
    var isSending = false
    var conflict = false
    var missing = false
    var deleted = false
    var error: String?
    private var epoch: Int?
    private let newEntry: Bool
    var pendingPhotos: [PendingPhoto] = []
    var photoContent: [String: Data] = [:]
    var isAddingPhotos = false
    init(id: String, newEntry: Bool = false) { self.id = id; self.newEntry = newEntry; isEditing = newEntry }
    private func current(_ app: AppModel) -> Bool { epoch == app.journalEpoch && app.noticeSeen && !app.deleting }
    var hasChanges: Bool {
        if !pendingPhotos.isEmpty { return true }
        guard let stored else { return !value.text.isEmpty }
        return value.text != stored.text || value.eventDate != stored.eventDate || value.eventPrecision != stored.eventPrecision || value.isOngoing != stored.isOngoing || value.allowAnalysis != stored.allowAnalysis
    }
    func canSave(_ app: AppModel) -> Bool {
        let content = !value.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pendingPhotos.isEmpty || !(stored?.photos.isEmpty ?? true)
        return content && (value.text.isEmpty || !value.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) && value.text.unicodeScalars.count <= app.limits.maxMemoryChars && !isLoading && !isSending && !isAddingPhotos && !conflict && !missing
    }
    func load(_ app: AppModel) async {
        guard app.noticeSeen, !app.deleting, !isLoading, let client = app.client else { return }
        if let epoch, epoch != app.journalEpoch { return }
        epoch = app.journalEpoch
        if newEntry && stored == nil && !conflict { return }
        isLoading = true
        defer { isLoading = false }
        let result = await client.loadMemory(id)
        guard current(app) else { return }
        switch result {
        case let .success(memory):
            stored = memory; missing = false; error = nil
            if !isEditing { value = MemorySave(memory) }
            for photo in memory.photos {
                let result = await client.loadNotePhoto(id, photoID: photo.id)
                guard current(app) else { return }
                switch result {
                case let .success(data): photoContent[photo.id] = data
                case let .failure(failure): error = failure.message
                }
            }
        case let .failure(failure): missing = failure.code == "not_found"; error = failure.message
        }
    }
    @discardableResult
    func save(_ app: AppModel) async -> Bool {
        guard !isSending else { return false }
        guard app.noticeSeen, !app.deleting, let client = app.client else {
            error = "The journal is unavailable. Acknowledge the privacy notice and try again."
            return false
        }
        // A new note can be submitted before its view's initial load task runs.
        if epoch == nil && newEntry { epoch = app.journalEpoch }
        guard current(app) else { error = "This editor belongs to a previous journal. Reopen Notes and try again."; return false }
        guard canSave(app) else { error = "Add text or a photo within the character limit, and resolve any conflict before saving."; return false }
        isSending = true
        error = nil
        defer { isSending = false }
        let result = await client.saveMemory(id, value: value)
        guard current(app) else { return false }
        switch result {
        case let .success(memory):
            stored = memory; value = MemorySave(memory)
            while let photo = pendingPhotos.first {
                let result = await client.saveNotePhoto(id, photoID: photo.id, content: photo.content)
                guard current(app) else { return false }
                switch result {
                case let .success(saved):
                    stored?.photos.removeAll { $0.id == saved.id }
                    stored?.photos.append(saved); photoContent[saved.id] = photo.content
                    pendingPhotos.removeFirst()
                case let .failure(failure): error = "Note saved; photo upload failed. \(failure.message)"; return false
                }
            }
            isEditing = false; error = nil
            return true
        case let .failure(failure):
            conflict = failure.code == "revision_conflict"; missing = failure.code == "not_found"; error = failure.message
            return false
        }
    }
    func useStored() {
        guard let stored else { return }
        value = MemorySave(stored); pendingPhotos = []; isEditing = false; conflict = false; error = nil
    }
    func keepMine(both: Bool = false) {
        guard let stored else { return }
        if both { value.text += "\n\n" + stored.text }
        value.baseRevision = stored.revision; conflict = false; error = nil
    }
    func saveAsNew(_ app: AppModel) async {
        guard current(app), !isSending else { return }
        id = newID(); value.baseRevision = 0; stored = nil; missing = false; conflict = false
        await save(app)
    }
    func delete(_ app: AppModel) async {
        guard current(app), !isSending, let client = app.client else { return }
        isSending = true
        defer { isSending = false }
        let result = await client.deleteMemory(id)
        guard current(app) else { return }
        switch result {
        case .success: deleted = true
        case let .failure(failure):
            if failure.code == "not_found" { deleted = true }
            else { error = failure.message }
        }
    }
    func addPhotos(_ items: [PhotosPickerItem], app: AppModel) async {
        guard current(app), !isSending, !isAddingPhotos else { return }
        isAddingPhotos = true
        defer { isAddingPhotos = false }
        for item in items {
            guard pendingPhotos.count + (stored?.photos.count ?? 0) < 5 else { error = "A note can hold at most 5 photos."; return }
            do {
                guard let data = try await item.loadTransferable(type: Data.self), data.count <= 20000000,
                      let image = UIImage(data: data), image.size.width > 0, image.size.height > 0 else { error = "Could not read this photo, or it exceeds 20 MB."; return }
                guard current(app) else { return }
                // Encoding a smaller JPEG bounds storage and removes the original location metadata.
                let factor = min(1, 1600 / max(image.size.width, image.size.height))
                let size = CGSize(width: image.size.width * factor, height: image.size.height * factor)
                let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
                let reduced = UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
                guard let content = reduced.jpegData(compressionQuality: 0.8), content.count <= 5000000 else { error = "Photo must be at most 5 MB after resizing."; return }
                pendingPhotos.append(PendingPhoto(id: newID(), content: content)); error = nil
            } catch { self.error = "Could not load the selected photo. Try again."; return }
        }
    }
    func deletePhoto(_ photoID: String, app: AppModel) async {
        guard current(app), !isSending, let client = app.client else { return }
        isSending = true
        defer { isSending = false }
        let result = await client.deleteNotePhoto(id, photoID: photoID)
        guard current(app) else { return }
        if case let .failure(failure) = result, failure.code != "not_found" { error = failure.message; return }
        stored?.photos.removeAll { $0.id == photoID }; photoContent.removeValue(forKey: photoID)
    }
}
