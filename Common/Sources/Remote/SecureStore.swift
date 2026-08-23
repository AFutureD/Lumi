import Foundation
import Security

public enum SecureStoreError: Error, Sendable {
    case unhandledStatus(OSStatus)
    case invalidData
}

public struct SecureStore: Sendable {
    public let service: String

    public init(service: String) {
        self.service = service
    }

    public func save<Value: Encodable>(_ value: Value, account: String) throws {
        let data = try JSONEncoder().encode(value)
        let query = baseQuery(account: account)
        let attributes: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insertion = query
            insertion[kSecValueData as String] = data
            let insertionStatus = SecItemAdd(insertion as CFDictionary, nil)
            guard insertionStatus == errSecSuccess else {
                throw SecureStoreError.unhandledStatus(insertionStatus)
            }
        } else if status != errSecSuccess {
            throw SecureStoreError.unhandledStatus(status)
        }
    }

    public func load<Value: Decodable>(_ type: Value.Type, account: String) throws -> Value? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw SecureStoreError.unhandledStatus(status) }
        guard let data = result as? Data else { throw SecureStoreError.invalidData }
        return try JSONDecoder().decode(type, from: data)
    }

    public func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecureStoreError.unhandledStatus(status)
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
    }
}
