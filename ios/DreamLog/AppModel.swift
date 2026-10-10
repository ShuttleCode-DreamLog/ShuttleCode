import Foundation
import Observation
import UserNotifications

@MainActor @Observable
final class AppModel {
    var me: Me?
    var limits = Limits()
    var error: String?
    var ready = false
    var noticeSeen = false
    var hasPriorAcknowledgment = false
    var deleting = false
    var deleteFailed = false
    var savingSettings = false
    var streamInProgress = false
    var recording = false
    var isBusy: Bool { recording || streamInProgress || savingSettings }
    var canCancelDeletion: Bool { !cleanupStarted }
    var settingsAvailable: Bool { me != nil && !loading && !savingSettings && !deleting }
    private(set) var client: APIClient?
    let store: LocalStore
    private let defaults: UserDefaults
    private let identity: Identity
    private let baseURL: URL
    private let configuration: URLSessionConfiguration
    private var alignmentAttempted = false
    private var loading = false
    var journalEpoch: Int { operation }
    private var operation = 0
    private var cleanupStarted = false

    init(defaults: UserDefaults = .standard, identity: Identity = Identity(), baseURL: URL = URL(string: Bundle.main.object(forInfoDictionaryKey: "DreamLogServerURL") as? String ?? "https://127.0.0.1:8443")!, folder: URL? = nil, configuration: URLSessionConfiguration = .ephemeral) {
        self.defaults = defaults
        self.identity = identity
        self.baseURL = baseURL
        self.configuration = configuration
        store = LocalStore(folder: folder ?? URL.applicationSupportDirectory.appending(path: "DreamLog"))
    }
    func start() async {
        guard !ready && !loading else { return }
        loading = true
        defer { loading = false }
        error = nil
        let pending = defaults.bool(forKey: deletionKey)
        switch identity.read() {
        case let .failure(failure): error = "Could not read this device’s journal identity: \(failure). Unlock the phone and try again."; return
        case let .success(existing):
            if pending, let existing {
                client = APIClient(baseURL: baseURL, identity: existing, configuration: configuration)
                deleting = true
                ready = true
                loading = false
                await requestDeletion()
                return
            }
            if existing == nil {
                clearDefaults()
                defaults.removeObject(forKey: deletionKey)
                guard case .success = await store.deleteEverything() else { error = "Could not clear the previous local journal."; return }
                switch identity.create() {
                case let .failure(failure): error = "Could not store the journal identity: \(failure)."; return
                case let .success(value): client = APIClient(baseURL: baseURL, identity: value, configuration: configuration)
                }
            } else if let existing { client = APIClient(baseURL: baseURL, identity: existing, configuration: configuration) }
        }
        guard case .success = await store.open() else { error = "Could not open the local journal. Unlock the phone and try again."; return }
        refreshNotice()
        ready = true
        loading = false
        if noticeSeen { await load() }
    }
    private func refreshNotice() {
        hasPriorAcknowledgment = defaults.object(forKey: noticeKey) != nil
        noticeSeen = defaults.integer(forKey: noticeKey) == noticeVersion && defaults.string(forKey: noticeContentKey) == noticeFingerprint
        client?.noticeAcknowledged = noticeSeen
    }
    func acknowledgeNotice() async {
        defaults.set(noticeVersion, forKey: noticeKey)
        defaults.set(noticeFingerprint, forKey: noticeContentKey)
        refreshNotice()
        await load()
    }
    func load() async {
        guard ready, noticeSeen, !deleting, !loading, !savingSettings, let client else { return }
        loading = true
        let current = operation
        defer { loading = false }
        switch await client.loadMe() {
        case let .failure(failure): if current == operation { error = failure.message }
        case let .success(value):
            guard current == operation, !deleting else { return }
            me = value; limits = value.limits; error = nil
            if !alignmentAttempted && (value.timezone != TimeZone.current.identifier || value.reminderWeekday != nil) {
                alignmentAttempted = true
                switch await client.saveMe(SettingsSave(timezone: TimeZone.current.identifier, reminderWeekday: nil, useHistory: value.useHistory)) {
                case let .success(saved): if current == operation { me = saved; limits = saved.limits }
                case let .failure(failure): if current == operation { error = failure.message }
                }
            }
        }
    }
    func saveHistory(_ enabled: Bool) async {
        guard settingsAvailable, let client, noticeSeen else { return }
        savingSettings = true
        let current = operation
        defer { savingSettings = false }
        switch await client.saveMe(SettingsSave(timezone: TimeZone.current.identifier, reminderWeekday: nil, useHistory: enabled)) {
        case let .success(saved): if current == operation { self.me = saved; limits = saved.limits; error = nil }
        case let .failure(failure): if current == operation { error = failure.message }
        }
    }
    func deleteJournal() async {
        guard !isBusy, !deleting, let client else { return }
        deleting = true; deleteFailed = false; error = nil; operation += 1
        await client.cancelAndWait()
        self.client = nil
        defaults.set(true, forKey: deletionKey)
        await retryDeletion()
    }
    func retryDeletion() async {
        if cleanupStarted { await erasePhone(); return }
        if client == nil {
            switch identity.read() {
            case let .success(value?): client = APIClient(baseURL: baseURL, identity: value, configuration: configuration)
            default: deleteFailed = true; error = "Could not read the journal identity. Retry after unlocking the phone."; return
            }
        }
        defaults.set(true, forKey: deletionKey)
        await requestDeletion()
    }
    func requestDeletion() async {
        guard let client else { return }
        deleteFailed = false
        switch await client.deleteMe() {
        case .success: await erasePhone()
        case let .failure(failure):
            if failure == .notSent { defaults.removeObject(forKey: deletionKey) }
            deleteFailed = true; error = failure.message
        }
    }
    func erasePhone() async {
        cleanupStarted = true
        defaults.set(true, forKey: deletionKey)
        if let client { await client.cancelAndWait() }
        client = nil
        guard case .success = await store.deleteEverything() else { deleteFailed = true; error = "Could not erase the local journal. Try again."; return }
        let cache = URL.cachesDirectory.appending(path: "DreamLog")
        let cacheResult = Result { if FileManager.default.fileExists(atPath: cache.path) { try FileManager.default.removeItem(at: cache) } }
        guard case .success = cacheResult else { deleteFailed = true; error = "Could not erase cached files. Try again."; return }
        clearDefaults()
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        guard case .success = identity.delete() else { deleteFailed = true; error = "Could not remove the journal identity. Try again."; return }
        defaults.removeObject(forKey: deletionKey)
        me = nil; limits = Limits(); deleting = false; deleteFailed = false; ready = false
        cleanupStarted = false; alignmentAttempted = false; operation += 1; error = nil
        await start()
    }
    func cancelDeletion() async {
        defaults.removeObject(forKey: deletionKey)
        deleting = false; deleteFailed = false; error = nil
        ready = false
        await start()
    }
    private func clearDefaults() {
        for key in [noticeKey, noticeContentKey, reminderKey, answeredOffersKey] { defaults.removeObject(forKey: key) }
    }
}
