import Foundation
import Synchronization
import SQLite3
import Testing
@testable import DreamLog

nonisolated final class BackendProtocol: URLProtocol, @unchecked Sendable {
    struct State: Sendable {
        var requests: [URLRequest] = []
        var responses: [(Int, Data)] = []
        var started: AsyncStream<Void>.Continuation?
        var cancelled = 0
    }
    static let state = Mutex(State())
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = Self.state.withLock { state in
            state.requests.append(request)
            return state.responses.isEmpty ? (500, Data()) : state.responses.removeFirst()
        }
        if response.0 == 0 {
            _ = Self.state.withLock { $0.started?.yield(()) }
            return
        }
        let http = HTTPURLResponse(url: request.url!, statusCode: response.0, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.1)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { Self.state.withLock { $0.cancelled += 1 } }
}

@Suite(.serialized) @MainActor
struct FoundationTests {
    func configuration() -> URLSessionConfiguration {
        BackendProtocol.state.withLock { $0 = .init() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BackendProtocol.self]
        return configuration
    }
    func response(history: Bool, zone: String? = nil) throws -> Data {
        let me = Me(userId: newID(), timezone: zone, reminderWeekday: nil, useHistory: history, limits: Limits(), usage: [], checkinKeepDays: 14)
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return try encoder.encode(me)
    }
    func enqueue(_ responses: [(Int, Data)]) { BackendProtocol.state.withLock { $0.responses = responses } }

    @Test func clientGatesRequestsUntilNotice() async {
        let client = APIClient(baseURL: URL(string: "https://localhost:8443")!, identity: newID(), configuration: configuration())
        if case let .failure(error) = await client.loadMe() { #expect(error == .noticeRequired) }
        else { Issue.record("A request escaped the privacy gate") }
        #expect(BackendProtocol.state.withLock { $0.requests.isEmpty })
        await client.cancelAndWait()
    }

    @Test func settingsEncodeExplicitNull() throws {
        let body = try JSONEncoder().encode(SettingsSave(timezone: "America/Detroit", reminderWeekday: nil, useHistory: false))
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(object["reminder_weekday"] is NSNull)
        #expect(object["use_history"] as? Bool == false)
    }

    @Test func bearerOnEveryRequestAndDeleteAllowedAtNotice() async throws {
        let identity = newID()
        let client = APIClient(baseURL: URL(string: "https://localhost:8443")!, identity: identity, configuration: configuration())
        enqueue([(200, try response(history: false)), (200, try response(history: true)), (204, Data())])
        client.noticeAcknowledged = true
        _ = await client.loadMe()
        _ = await client.saveMe(SettingsSave(timezone: "America/Detroit", reminderWeekday: nil, useHistory: true))
        client.noticeAcknowledged = false
        _ = await client.deleteMe()
        let requests = BackendProtocol.state.withLock { $0.requests }
        #expect(requests.map(\.httpMethod) == ["GET", "PUT", "DELETE"])
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer \(identity)" })
        await client.cancelAndWait()
    }

    @Test func acknowledgedLaunchAlignsOnceAndKeepsServerHistory() async throws {
        let config = configuration()
        let namespace = "foundation-tests-\(newID())"
        let defaults = try #require(UserDefaults(suiteName: namespace))
        let identity = Identity(service: namespace)
        let folder = URL.temporaryDirectory.appending(path: namespace)
        defer { _ = identity.delete(); defaults.removePersistentDomain(forName: namespace) }
        _ = identity.create()
        defaults.set(noticeVersion, forKey: noticeKey)
        defaults.set(noticeFingerprint, forKey: noticeContentKey)
        enqueue([(200, try response(history: false)), (200, try response(history: false)), (200, try response(history: false))])
        let model = AppModel(defaults: defaults, identity: identity, folder: folder, configuration: config)
        await model.start()
        await model.load()
        #expect(model.me?.useHistory == false)
        #expect(BackendProtocol.state.withLock { $0.requests.map(\.httpMethod) } == ["GET", "PUT", "GET"])
        if let client = model.client { await client.cancelAndWait() }
        _ = await model.store.deleteEverything()
    }

    @Test func noticeVersionGateAndDeletionResetIdentity() async throws {
        let config = configuration()
        let namespace = "foundation-tests-\(newID())"
        let defaults = try #require(UserDefaults(suiteName: namespace))
        let identity = Identity(service: namespace)
        let folder = URL.temporaryDirectory.appending(path: namespace)
        defer { _ = identity.delete(); defaults.removePersistentDomain(forName: namespace) }
        let first = try identity.create().get()
        defaults.set(noticeVersion - 1, forKey: noticeKey)
        defaults.set(noticeFingerprint, forKey: noticeContentKey)
        let model = AppModel(defaults: defaults, identity: identity, folder: folder, configuration: config)
        await model.start()
        #expect(model.ready && !model.noticeSeen && model.hasPriorAcknowledgment)
        #expect(BackendProtocol.state.withLock { $0.requests.isEmpty })
        enqueue([(204, Data())])
        await model.deleteJournal()
        #expect(model.ready && !model.noticeSeen && !model.hasPriorAcknowledgment)
        #expect(try identity.read().get() != first)
        #expect(!defaults.bool(forKey: deletionKey))
        #expect(defaults.object(forKey: noticeContentKey) == nil)
        #expect(BackendProtocol.state.withLock { $0.requests.map(\.httpMethod) } == ["DELETE"])
        if let client = model.client { await client.cancelAndWait() }
        _ = await model.store.deleteEverything()
    }

    @Test(arguments: [nil, String(repeating: "0", count: 64)] as [String?])
    func changedOrLegacyNoticeBlocksRequestsAndAllowsDeletion(fingerprint: String?) async throws {
        let config = configuration()
        let namespace = "notice-content-tests-\(newID())"
        let defaults = try #require(UserDefaults(suiteName: namespace))
        let identity = Identity(service: namespace)
        defer { _ = identity.delete(); defaults.removePersistentDomain(forName: namespace) }
        let first = try identity.create().get()
        defaults.set(noticeVersion, forKey: noticeKey)
        defaults.set(fingerprint, forKey: noticeContentKey)
        let model = AppModel(defaults: defaults, identity: identity, folder: URL.temporaryDirectory.appending(path: namespace), configuration: config)
        await model.start()
        await model.load()
        #expect(model.ready && !model.noticeSeen && model.hasPriorAcknowledgment)
        let client = try #require(model.client)
        if case let .failure(error) = await client.loadMe() { #expect(error == .noticeRequired) }
        else { Issue.record("Changed notice allowed an API request") }
        #expect(BackendProtocol.state.withLock { $0.requests.isEmpty })
        enqueue([(204, Data())])
        await model.deleteJournal()
        #expect(model.ready && !model.noticeSeen && !model.hasPriorAcknowledgment)
        #expect(try identity.read().get() != first)
        #expect(defaults.object(forKey: noticeContentKey) == nil)
        #expect(BackendProtocol.state.withLock { $0.requests.map(\.httpMethod) } == ["DELETE"])
        if let client = model.client { await client.cancelAndWait() }
        _ = await model.store.deleteEverything()
    }

    @Test func acknowledgmentStoresContentAndNextLaunchAcceptsIt() async throws {
        let config = configuration()
        let namespace = "notice-ack-tests-\(newID())"
        let defaults = try #require(UserDefaults(suiteName: namespace))
        let identity = Identity(service: namespace)
        defer { _ = identity.delete(); defaults.removePersistentDomain(forName: namespace) }
        _ = try identity.create().get()
        defaults.set(noticeVersion, forKey: noticeKey)
        defaults.set("previous content", forKey: noticeContentKey)
        let model = AppModel(defaults: defaults, identity: identity, folder: URL.temporaryDirectory.appending(path: namespace), configuration: config)
        await model.start()
        #expect(!model.noticeSeen)
        enqueue([(200, try response(history: false, zone: TimeZone.current.identifier))])
        await model.acknowledgeNotice()
        #expect(model.noticeSeen && defaults.string(forKey: noticeContentKey) == noticeFingerprint)
        if let client = model.client { await client.cancelAndWait() }
        _ = await model.store.deleteEverything()
        enqueue([(200, try response(history: false, zone: TimeZone.current.identifier))])
        let relaunched = AppModel(defaults: defaults, identity: identity, folder: URL.temporaryDirectory.appending(path: namespace), configuration: config)
        await relaunched.start()
        #expect(relaunched.noticeSeen && relaunched.me?.useHistory == false)
        #expect(BackendProtocol.state.withLock { $0.requests.map(\.httpMethod) } == ["GET", "GET"])
        if let client = relaunched.client { await client.cancelAndWait() }
        _ = await relaunched.store.deleteEverything()
    }

    @Test func freshIdentityDiscardsRestoredAcknowledgment() async throws {
        let config = configuration()
        let namespace = "foundation-tests-\(newID())"
        let defaults = try #require(UserDefaults(suiteName: namespace))
        let identity = Identity(service: namespace)
        defer { _ = identity.delete(); defaults.removePersistentDomain(forName: namespace) }
        defaults.set(noticeVersion, forKey: noticeKey)
        defaults.set(noticeFingerprint, forKey: noticeContentKey)
        let model = AppModel(defaults: defaults, identity: identity, folder: URL.temporaryDirectory.appending(path: namespace), configuration: config)
        await model.start()
        #expect(model.ready && !model.noticeSeen)
        #expect(defaults.object(forKey: noticeContentKey) == nil)
        #expect(BackendProtocol.state.withLock { $0.requests.isEmpty })
        if let client = model.client { await client.cancelAndWait() }
        _ = await model.store.deleteEverything()
    }

    @Test func failedDeletionKeepsIdentityAndCanBeCancelled() async throws {
        let config = configuration()
        let namespace = "foundation-tests-\(newID())"
        let defaults = try #require(UserDefaults(suiteName: namespace))
        let identity = Identity(service: namespace)
        defer { _ = identity.delete(); defaults.removePersistentDomain(forName: namespace) }
        let first = try identity.create().get()
        defaults.set(noticeVersion - 1, forKey: noticeKey)
        let model = AppModel(defaults: defaults, identity: identity, folder: URL.temporaryDirectory.appending(path: namespace), configuration: config)
        await model.start()
        enqueue([(500, Data("{\"error\":\"internal\",\"message\":\"Try again\"}".utf8))])
        await model.deleteJournal()
        #expect(model.deleting && model.deleteFailed && defaults.bool(forKey: deletionKey))
        #expect(try identity.read().get() == first)
        await model.cancelDeletion()
        #expect(!model.deleting && !defaults.bool(forKey: deletionKey))
        #expect(model.hasPriorAcknowledgment && !model.noticeSeen)
        #expect(BackendProtocol.state.withLock { $0.requests.map(\.httpMethod) } == ["DELETE"])
        if let client = model.client { await client.cancelAndWait() }
        _ = await model.store.deleteEverything()
    }

    @Test func interruptedDeletionResumesBeforeNormalRequests() async throws {
        let config = configuration()
        let namespace = "foundation-tests-\(newID())"
        let defaults = try #require(UserDefaults(suiteName: namespace))
        let identity = Identity(service: namespace)
        defer { _ = identity.delete(); defaults.removePersistentDomain(forName: namespace) }
        let first = try identity.create().get()
        defaults.set(noticeVersion, forKey: noticeKey)
        defaults.set(noticeFingerprint, forKey: noticeContentKey)
        defaults.set(true, forKey: deletionKey)
        enqueue([(204, Data())])
        let model = AppModel(defaults: defaults, identity: identity, folder: URL.temporaryDirectory.appending(path: namespace), configuration: config)
        await model.start()
        #expect(model.ready && !model.noticeSeen && !model.deleting)
        #expect(try identity.read().get() != first)
        #expect(BackendProtocol.state.withLock { $0.requests.map(\.httpMethod) } == ["DELETE"])
        if let client = model.client { await client.cancelAndWait() }
        _ = await model.store.deleteEverything()
    }

    @Test func historyChangeAdoptsServerResponseAndBusyDeletionSendsNothing() async throws {
        let config = configuration()
        let namespace = "foundation-tests-\(newID())"
        let defaults = try #require(UserDefaults(suiteName: namespace))
        let identity = Identity(service: namespace)
        defer { _ = identity.delete(); defaults.removePersistentDomain(forName: namespace) }
        _ = try identity.create().get()
        defaults.set(noticeVersion, forKey: noticeKey)
        defaults.set(noticeFingerprint, forKey: noticeContentKey)
        enqueue([(200, try response(history: false, zone: TimeZone.current.identifier)), (200, try response(history: false, zone: TimeZone.current.identifier))])
        let model = AppModel(defaults: defaults, identity: identity, folder: URL.temporaryDirectory.appending(path: namespace), configuration: config)
        await model.start()
        await model.saveHistory(true)
        #expect(model.me?.useHistory == false)
        model.recording = true
        await model.deleteJournal()
        #expect(!model.deleting)
        #expect(BackendProtocol.state.withLock { $0.requests.map(\.httpMethod) } == ["GET", "PUT"])
        if let client = model.client { await client.cancelAndWait() }
        _ = await model.store.deleteEverything()
    }

    @Test func cancellationWaitsForInFlightRequestToEnd() async {
        let config = configuration()
        let channel = AsyncStream<Void>.makeStream()
        BackendProtocol.state.withLock { $0.responses = [(0, Data())]; $0.started = channel.continuation }
        let client = APIClient(baseURL: URL(string: "https://localhost:8443")!, identity: newID(), configuration: config)
        client.noticeAcknowledged = true
        let request = Task { await client.loadMe() }
        for await _ in channel.stream { break }
        channel.continuation.finish()
        await client.cancelAndWait()
        if case let .failure(error) = await request.value { #expect(error == .interrupted) }
        else { Issue.record("A cancelled request completed successfully") }
        #expect(BackendProtocol.state.withLock { $0.cancelled } > 0)
    }

    @Test func incompatibleLocalSchemaIsNeverSilentlyReplaced() async throws {
        let folder = URL.temporaryDirectory.appending(path: "schema-test-\(newID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var database: OpaquePointer?
        #expect(sqlite3_open(folder.appending(path: "local.sqlite").path, &database) == SQLITE_OK)
        #expect(sqlite3_exec(database, "PRAGMA user_version=99", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(database)
        let store = LocalStore(folder: folder)
        for _ in 0..<2 {
            if case .failure = await store.open() {} else { Issue.record("An incompatible local database was accepted") }
        }
    }

    @Test func privacyHasExactlySixSharedParts() { #expect(privacyParts.count == 6) }
}
