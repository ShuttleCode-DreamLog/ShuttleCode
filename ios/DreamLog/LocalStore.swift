import Foundation
import SQLite3

actor LocalStore {
    let folder: URL
    private var database: OpaquePointer?
    init(folder: URL) { self.folder = folder }

    func open() -> Result<Void, StoreError> {
        guard database == nil else { return .success(()) }
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.complete])
            var protectedFolder = folder
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try protectedFolder.setResourceValues(values)
            let recordings = folder.appending(path: "Recordings")
            try manager.createDirectory(at: recordings, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.completeUnlessOpen])
            var protectedRecordings = recordings
            try protectedRecordings.setResourceValues(values)
        } catch { return .failure(.filesFailed) }
        guard sqlite3_open(folder.appending(path: "local.sqlite").path, &database) == SQLITE_OK else {
            if let database { sqlite3_close(database) }
            database = nil
            return .failure(.openFailed)
        }
        var version: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA user_version", -1, &version, nil) == SQLITE_OK else {
            sqlite3_close(database)
            database = nil
            return .failure(.openFailed)
        }
        let hasVersion = sqlite3_step(version) == SQLITE_ROW
        let storedVersion = sqlite3_column_int(version, 0)
        sqlite3_finalize(version)
        guard hasVersion && (storedVersion == 0 || storedVersion == 1) else {
            sqlite3_close(database)
            database = nil
            return .failure(.openFailed)
        }
        let sql = """
        CREATE TABLE IF NOT EXISTS drafts (
            dream_id TEXT PRIMARY KEY,text TEXT NOT NULL DEFAULT '',title TEXT,mood TEXT,
            dream_date TEXT NOT NULL,source TEXT NOT NULL,permissions TEXT NOT NULL,
            base_revision INTEGER NOT NULL DEFAULT 0,unsent INTEGER NOT NULL DEFAULT 1,
            conflict INTEGER NOT NULL DEFAULT 0,audio_file TEXT,audio_ms INTEGER,
            audio_uploaded INTEGER NOT NULL DEFAULT 0,audio_send_started INTEGER NOT NULL DEFAULT 0,
            unconfirmed INTEGER NOT NULL DEFAULT 0,sent_text TEXT,updated_at INTEGER NOT NULL
        );
        PRAGMA user_version=1;
        """
        let status = sqlite3_exec(database, sql, nil, nil, nil)
        guard status == SQLITE_OK else {
            sqlite3_close(database)
            database = nil
            return .failure(.statementFailed(code: status))
        }
        return .success(())
    }
    func saveDraft(_ draft: Draft) -> Result<Void, StoreError> {
        guard let database else { return .failure(.openFailed) }
        guard let permissions = try? JSONEncoder().encode(draft.permissions), let permissionText = String(data: permissions, encoding: .utf8) else { return .failure(.filesFailed) }
        let columns = ["dream_id", "text", "title", "mood", "dream_date", "source", "permissions", "base_revision", "unsent", "conflict", "audio_file", "audio_ms", "audio_uploaded", "audio_send_started", "unconfirmed", "sent_text", "updated_at"]
        let sql = "INSERT INTO drafts(\(columns.joined(separator: ","))) VALUES(\(Array(repeating: "?", count: columns.count).joined(separator: ","))) ON CONFLICT(dream_id) DO UPDATE SET \(columns.dropFirst().map { "\($0)=excluded.\($0)" }.joined(separator: ","))"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return .failure(.statementFailed(code: sqlite3_errcode(database))) }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let texts: [(Int32, String?)] = [(1,draft.dreamId),(2,draft.text),(3,draft.title),(4,draft.mood?.rawValue),(5,draft.dreamDate),(6,draft.source.rawValue),(7,permissionText),(11,draft.audioFile),(16,draft.sentText)]
        for (column, value) in texts {
            if let value { sqlite3_bind_text(statement, column, value, -1, transient) }
            else { sqlite3_bind_null(statement, column) }
        }
        let numbers: [(Int32, Int64?)] = [(8,Int64(draft.baseRevision)),(9,draft.unsent ? 1 : 0),(10,draft.conflict ? 1 : 0),(12,draft.audioMs.map(Int64.init)),(13,draft.audioUploaded ? 1 : 0),(14,draft.audioSendStarted ? 1 : 0),(15,draft.unconfirmed ? 1 : 0),(17,Int64(draft.updatedAt.timeIntervalSince1970 * 1000))]
        for (column, value) in numbers {
            if let value { sqlite3_bind_int64(statement, column, value) }
            else { sqlite3_bind_null(statement, column) }
        }
        let status = sqlite3_step(statement)
        return status == SQLITE_DONE ? .success(()) : .failure(.statementFailed(code: status))
    }
    func drafts(_ id: String? = nil) -> Result<[Draft], StoreError> {
        guard let database else { return .failure(.openFailed) }
        var statement: OpaquePointer?
        let sql = "SELECT dream_id,text,title,mood,dream_date,source,permissions,base_revision,unsent,conflict,audio_file,audio_ms,audio_uploaded,audio_send_started,unconfirmed,sent_text,updated_at FROM drafts" + (id == nil ? "" : " WHERE dream_id=?") + " ORDER BY updated_at DESC,dream_id"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return .failure(.statementFailed(code: sqlite3_errcode(database))) }
        defer { sqlite3_finalize(statement) }
        if let id { sqlite3_bind_text(statement, 1, id, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        func text(_ column: Int32) -> String? {
            guard let value = sqlite3_column_text(statement, column) else { return nil }
            return String(cString: value)
        }
        var drafts: [Draft] = []
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            guard let id = text(0), let content = text(1), let date = text(4), let source = text(5), let permissions = text(6), let decoded = try? JSONDecoder().decode(Permissions.self, from: Data(permissions.utf8)) else { return .failure(.statementFailed(code: SQLITE_CORRUPT)) }
            var draft = Draft(dreamId: id, dreamDate: date)
            draft.text = content; draft.title = text(2); draft.mood = text(3).map { Mood(rawValue: $0) ?? .unknown }
            draft.source = DreamSource(rawValue: source) ?? .unknown; draft.permissions = decoded
            draft.baseRevision = Int(sqlite3_column_int64(statement, 7)); draft.unsent = sqlite3_column_int(statement, 8) != 0
            draft.conflict = sqlite3_column_int(statement, 9) != 0; draft.audioFile = text(10)
            draft.audioMs = sqlite3_column_type(statement, 11) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(statement, 11))
            draft.audioUploaded = sqlite3_column_int(statement, 12) != 0; draft.audioSendStarted = sqlite3_column_int(statement, 13) != 0
            draft.unconfirmed = sqlite3_column_int(statement, 14) != 0; draft.sentText = text(15)
            draft.updatedAt = Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, 16)) / 1000)
            drafts.append(draft)
            status = sqlite3_step(statement)
        }
        return status == SQLITE_DONE ? .success(drafts) : .failure(.statementFailed(code: status))
    }
    func draft(_ id: String) -> Result<Draft?, StoreError> { drafts(id).map { $0.first { $0.dreamId == id } } }
    func deleteDraft(_ id: String) -> Result<Void, StoreError> {
        guard let database else { return .failure(.openFailed) }
        let existing = draft(id)
        guard case let .success(draft) = existing else { return existing.map { _ in () } }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "DELETE FROM drafts WHERE dream_id=?", -1, &statement, nil) == SQLITE_OK else { return .failure(.statementFailed(code: sqlite3_errcode(database))) }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, id, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        let status = sqlite3_step(statement)
        guard status == SQLITE_DONE else { return .failure(.statementFailed(code: status)) }
        if let recording = draft?.audioFile {
            return Result { try FileManager.default.removeItem(at: folder.appending(path: "Recordings").appending(path: recording)) }.mapError { _ in .filesFailed }
        }
        return .success(())
    }
    func deleteEverything() -> Result<Void, StoreError> {
        if let database {
            guard sqlite3_close(database) == SQLITE_OK else { return .failure(.filesFailed) }
            self.database = nil
        }
        return Result {
            if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
        }.mapError { _ in .filesFailed }
    }
}
