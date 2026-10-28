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
    // A streamed reply may take as long as the server's provider call, past the 60-second limit of ordinary requests.
    private let streaming: URLSession
    private let streamingInvalidation: AsyncStream<Void>
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
        let long = (configuration.copy() as? URLSessionConfiguration) ?? .ephemeral
        long.timeoutIntervalForResource = 180
        let streamChannel = AsyncStream<Void>.makeStream()
        streamingInvalidation = streamChannel.stream
        streaming = URLSession(configuration: long, delegate: SessionDelegate(invalidated: streamChannel.continuation), delegateQueue: nil)
    }
    func cancelAndWait() async {
        noticeAcknowledged = false
        session.invalidateAndCancel()
        streaming.invalidateAndCancel()
        for await _ in invalidation { break }
        for await _ in streamingInvalidation { break }
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
    private func send<Body: Encodable, Value: Decodable>(_ method: String, _ path: String, _ value: Body, query: [URLQueryItem] = []) async -> Result<Value, APIError> {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        guard let body = try? encoder.encode(value) else { return .failure(.decoding) }
        return decode(await response(method: method, path: path, query: query, body: body))
    }
    func savePermissions(_ id: String, _ value: [String: Bool]) async -> Result<Dream, APIError> {
        let result: Result<DreamResponse, APIError> = await send("PUT", "v1/dreams/\(id)/permissions", value)
        return result.map(\.dream)
    }
    func saveCorrection(_ id: String, _ value: DreamCorrection) async -> Result<Dream, APIError> {
        let result: Result<DreamResponse, APIError> = await send("PUT", "v1/dreams/\(id)/corrections", value)
        return result.map(\.dream)
    }
    func retryTask(_ id: String) async -> Result<TaskInfo, APIError> {
        let result: Result<TaskResponse, APIError> = decode(await response(method: "POST", path: "v1/tasks/\(id)/retry"))
        return result.map(\.task)
    }
    func loadAnalysis(_ dreamID: String) async -> Result<AnalysisResponse, APIError> {
        decode(await response(method: "GET", path: "v1/dreams/\(dreamID)/analysis"))
    }
    func refreshAnalysis(_ dreamID: String, refreshID: String) async -> Result<TaskInfo, APIError> {
        let result: Result<TaskResponse, APIError> = await send("POST", "v1/dreams/\(dreamID)/analysis/refresh", RefreshRequest(refreshId: refreshID))
        return result.map(\.task)
    }
    func loadConversation(_ dreamID: String) async -> Result<Conversation, APIError> {
        let result: Result<ConversationResponse, APIError> = decode(await response(method: "GET", path: "v1/dreams/\(dreamID)/conversation"))
        return result.map(\.conversation)
    }
    func restartConversation(_ dreamID: String) async -> Result<Conversation, APIError> {
        let result: Result<ConversationResponse, APIError> = decode(await response(method: "POST", path: "v1/dreams/\(dreamID)/conversation/restart"))
        return result.map(\.conversation)
    }
    // Reads the server-sent events of a discussion turn line by line (wiki 4.2.5); cancelling the consuming task ends the request.
    // It keeps response()'s notice gate and Bearer identity, on its own session with the longer limit.
    func sendTurn(_ dreamID: String, messageID: String, text: String) -> AsyncStream<TurnEvent> {
        let (events, continuation) = AsyncStream<TurnEvent>.makeStream()
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let body = try? encoder.encode(TurnRequest(messageId: messageID, text: text))
        let refusal: APIError? = !noticeAcknowledged ? .noticeRequired : baseURL.scheme != "https" ? .notSent : body == nil ? .decoding : nil
        var request = URLRequest(url: baseURL.appending(path: "v1/dreams/\(dreamID)/conversation/messages"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(identity)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let failure = { (status: Int, data: Data) -> TurnEvent in
            let error = try? decoder.decode(ServerError.self, from: data)
            return .failed(.server(status: status, code: error?.error ?? "unreadable", message: error?.message ?? "The server returned an unreadable error."))
        }
        let reading = Task { [streaming] in
            defer { continuation.finish() }
            if let refusal { continuation.yield(.failed(refusal)); return }
            do {
                let (bytes, response) = try await streaming.bytes(for: request)
                guard let response = response as? HTTPURLResponse else { continuation.yield(.failed(.noAnswer)); return }
                guard (200..<300).contains(response.statusCode) else {
                    var data = Data()
                    for try await byte in bytes { data.append(byte) }
                    continuation.yield(failure(response.statusCode, data))
                    return
                }
                var name = ""
                for try await line in bytes.lines {
                    if line.hasPrefix("event:") { name = line.dropFirst(6).trimmingCharacters(in: .whitespaces); continue }
                    guard line.hasPrefix("data:") else { continue }
                    let data = Data(line.dropFirst(5).trimmingCharacters(in: .whitespaces).utf8)
                    let event: TurnEvent? = switch name {
                    case "start": (try? decoder.decode(TurnStart.self, from: data)).map { .start(contextRestarted: $0.contextRestarted) }
                    case "delta": (try? decoder.decode(TurnDelta.self, from: data)).map { .delta($0.text) }
                    case "done": .some((try? decoder.decode(TurnDone.self, from: data)).map { .done($0) } ?? .failed(.decoding))
                    case "error": failure(200, data)
                    default: nil
                    }
                    guard let event else { continue }
                    continuation.yield(event)
                    if case .done = event { return }
                    if case .failed = event { return }
                }
                continuation.yield(.failed(.interrupted))
            } catch {
                let code = (error as? URLError)?.code
                let failed: APIError = switch code {
                case .cancelled: .interrupted
                case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .notConnectedToInternet,
                     .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot,
                     .serverCertificateNotYetValid, .secureConnectionFailed: .notSent
                default: error is CancellationError ? .interrupted : .noAnswer
                }
                continuation.yield(.failed(failed))
            }
        }
        continuation.onTermination = { _ in reading.cancel() }
        return events
    }
    func loadPatterns() async -> Result<PatternsResponse, APIError> { decode(await response(method: "GET", path: "v1/patterns")) }
    func loadTags() async -> Result<TagList, APIError> { decode(await response(method: "GET", path: "v1/tags")) }
    func labelPattern(_ groupID: String, _ value: PatternLabel) async -> Result<PatternsResponse, APIError> {
        await send("PUT", "v1/patterns/groups/\(groupID)/label", value)
    }
    func dismissPattern(_ groupID: String, _ value: PatternDismissal) async -> Result<PatternsResponse, APIError> {
        await send("POST", "v1/patterns/groups/\(groupID)/dismiss", value)
    }
    func splitPattern(_ groupID: String, _ value: PatternSplit) async -> Result<PatternsResponse, APIError> {
        await send("POST", "v1/patterns/groups/\(groupID)/split", value)
    }
}
