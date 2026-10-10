import Foundation
import Security

struct Identity {
    let service: String
    init(service: String = Bundle.main.bundleIdentifier ?? "edu.umich.dreamlog") { self.service = service }
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: "user-id", kSecAttrSynchronizable as String: false]
    }
    func read() -> Result<String?, IdentityError> {
        var attributes = query
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(attributes as CFDictionary, &value)
        if status == errSecItemNotFound { return .success(nil) }
        guard status == errSecSuccess else { return .failure(.keychainFailed(status: status)) }
        guard let data = value as? Data, let identity = String(data: data, encoding: .utf8),
              UUID(uuidString: identity)?.uuidString.lowercased() == identity else { return .failure(.invalidIdentity) }
        return .success(identity)
    }
    func create() -> Result<String, IdentityError> {
        let identity = newID()
        var attributes = query
        attributes[kSecValueData as String] = Data(identity.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            return read().flatMap { $0.map(Result.success) ?? .failure(.invalidIdentity) }
        }
        return status == errSecSuccess ? .success(identity) : .failure(.keychainFailed(status: status))
    }
    func delete() -> Result<Void, IdentityError> {
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound ? .success(()) : .failure(.keychainFailed(status: status))
    }
}
