import Foundation

private final class SessionDelegate: NSObject, URLSessionDelegate, Sendable {
    let invalidated: AsyncStream<Void>.Continuation
    init(invalidated: AsyncStream<Void>.Continuation) { self.invalidated = invalidated }
    nonisolated func urlSession(_ session: URLSession, didBecomeInvalidWithError error: (any Error)?) {
        invalidated.yield(())
        invalidated.finish()
    }
}

@MainActor
final class APIClient {
    let baseURL: URL
    let configuration: URLSessionConfiguration
    private let identity: String
    private let session: URLSession
    private let invalidation: AsyncStream<Void>
    var noticeAcknowledged = false

    init(baseURL: URL, identity: String, configuration: URLSessionConfiguration = .ephemeral) {
        self.baseURL = baseURL
        self.identity = identity
        self.configuration = configuration
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 60
        let channel = AsyncStream<Void>.makeStream()
        invalidation = channel.stream
        session = URLSession(configuration: configuration, delegate: SessionDelegate(invalidated: channel.continuation), delegateQueue: nil)
    }
    func cancelAndWait() async {
        noticeAcknowledged = false
        session.invalidateAndCancel()
        for await _ in invalidation { break }
    }
    private func response(method: String, path: String = "v1/me", query: [URLQueryItem] = [], body: Data? = nil, contentType: String = "application/json", deleting: Bool = false, empty: Bool = false) async -> Result<Data, APIError> {
        guard noticeAcknowledged || deleting else { return .failure(.noticeRequired) }
        guard baseURL.scheme == "https" else { return .failure(.notSent) }
        var request = URLRequest(url: baseURL.appending(path: path).appending(queryItems: query))
        request.httpMethod = method
        request.setValue("Bearer \(identity)", forHTTPHeaderField: "Authorization")
        if let body { request.httpBody = body; request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        do {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { return .failure(.noAnswer) }
            guard (200..<300).contains(response.statusCode) else {
                let decoder = JSONDecoder()
                decoder.keyDecodingStrategy = .convertFromSnakeCase
                let error = try? decoder.decode(ServerError.self, from: data)
                return .failure(.server(status: response.statusCode, code: error?.error ?? "unreadable", message: error?.message ?? "The server returned an unreadable error."))
            }
            if (deleting || empty) && response.statusCode != 204 { return .failure(.decoding) }
            return .success(data)
        } catch let error as URLError {
            let failure: APIError = switch error.code {
            case .cancelled: .interrupted
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .notConnectedToInternet,
                 .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot,
                 .serverCertificateNotYetValid, .secureConnectionFailed: .notSent
            default: .noAnswer
            }
            return .failure(failure)
        } catch { return .failure(.noAnswer) }
    }
    private func decode<Value: Decodable>(_ result: Result<Data, APIError>) -> Result<Value, APIError> {
        result.flatMap { data in
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            decoder.dateDecodingStrategy = .millisecondsSince1970
            return Result { try decoder.decode(Value.self, from: data) }.mapError { _ in .decoding }
        }
    }
    func loadMe() async -> Result<Me, APIError> { decode(await response(method: "GET")) }
    func saveMe(_ settings: SettingsSave) async -> Result<Me, APIError> {
        guard case let .success(body) = Result(catching: { try JSONEncoder().encode(settings) }) else { return .failure(.decoding) }
        return decode(await response(method: "PUT", body: body))
    }
    func loadJournal(filter: JournalFilter = JournalFilter(), offset: Int = 0) async -> Result<JournalPage, APIError> {
        let query = [URLQueryItem(name: "offset", value: String(offset))]
        if filter.isEmpty { return decode(await response(method: "GET", path: "v1/dreams", query: query)) }
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        guard let body = try? encoder.encode(filter) else { return .failure(.decoding) }
        return decode(await response(method: "POST", path: "v1/dreams/search", query: query, body: body))
    }
    func loadDream(_ id: String) async -> Result<Dream, APIError> {
        let result: Result<DreamResponse, APIError> = decode(await response(method: "GET", path: "v1/dreams/\(id)"))
        return result.map(\.dream)
    }
    func saveDream(_ id: String, value: DreamSave) async -> Result<Dream, APIError> {
        // AI integration point: add processing/status API methods here when the backend worker exists.
        // Provider credentials and the actual dream-processing API call stay on the backend.
        guard let body = try? JSONEncoder().encode(value) else { return .failure(.decoding) }
        let result: Result<DreamResponse, APIError> = decode(await response(method: "PUT", path: "v1/dreams/\(id)", body: body))
        return result.map(\.dream)
    }
    func deleteDream(_ id: String) async -> Result<Void, APIError> {
        await response(method: "DELETE", path: "v1/dreams/\(id)", empty: true).map { _ in () }
    }
    func deleteMe() async -> Result<Void, APIError> { await response(method: "DELETE", deleting: true).map { _ in () } }
    func loadMemories(offset: Int = 0) async -> Result<MemoryPage, APIError> {
        decode(await response(method: "GET", path: "v1/memories", query: [URLQueryItem(name: "offset", value: String(offset))]))
    }
    func loadMemory(_ id: String) async -> Result<Memory, APIError> {
        let result: Result<MemoryResponse, APIError> = decode(await response(method: "GET", path: "v1/memories/\(id)"))
        return result.map(\.memory)
    }
    func saveMemory(_ id: String, value: MemorySave) async -> Result<Memory, APIError> {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        guard let body = try? encoder.encode(value) else { return .failure(.decoding) }
        let result: Result<MemoryResponse, APIError> = decode(await response(method: "PUT", path: "v1/memories/\(id)", body: body))
        return result.map(\.memory)
    }
    func deleteMemory(_ id: String) async -> Result<Void, APIError> {
        await response(method: "DELETE", path: "v1/memories/\(id)", empty: true).map { _ in () }
    }
    func loadProfile() async -> Result<Profile, APIError> {
        let result: Result<ProfileResponse, APIError> = decode(await response(method: "GET", path: "v1/me/profile"))
        return result.map(\.profile)
    }
    func saveProfile(_ value: ProfileSave) async -> Result<Profile, APIError> {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        guard let body = try? encoder.encode(value) else { return .failure(.decoding) }
        let result: Result<ProfileResponse, APIError> = decode(await response(method: "PUT", path: "v1/me/profile", body: body))
        return result.map(\.profile)
    }
    func loadNotePhoto(_ memoryID: String, photoID: String) async -> Result<Data, APIError> {
        await response(method: "GET", path: "v1/memories/\(memoryID)/photos/\(photoID)")
    }
    func saveNotePhoto(_ memoryID: String, photoID: String, content: Data) async -> Result<NotePhoto, APIError> {
        let result: Result<PhotoResponse, APIError> = decode(await response(method: "PUT", path: "v1/memories/\(memoryID)/photos/\(photoID)", body: content, contentType: "image/jpeg"))
        return result.map(\.photo)
    }
    func deleteNotePhoto(_ memoryID: String, photoID: String) async -> Result<Void, APIError> {
        await response(method: "DELETE", path: "v1/memories/\(memoryID)/photos/\(photoID)", empty: true).map { _ in () }
    }
}
