import Foundation
import Security

/// Minimal key/value secret storage, protocol-wrapped so production code
/// depends on Keychain only through this seam and tests substitute an
/// in-memory fake — per `documentation/security.md` §Client-side token
/// storage: refresh tokens (and the stable device id) must live in Keychain,
/// never `UserDefaults` or a plist.
protocol SecureStore: Sendable {
    func read(_ key: String) throws -> String?
    func write(_ value: String, for key: String) throws
    func delete(_ key: String) throws
}

enum SecureStoreError: Error {
    case unhandled(status: OSStatus)
}

/// macOS Keychain-backed `SecureStore`, using a generic password item per
/// key under a fixed service name.
struct KeychainSecureStore: SecureStore {
    private let service: String

    init(service: String = "com.rizeclone.desktop.auth") {
        self.service = service
    }

    func read(_ key: String) throws -> String? {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
                return nil
            }
            return value
        case errSecItemNotFound:
            return nil
        default:
            throw SecureStoreError.unhandled(status: status)
        }
    }

    func write(_ value: String, for key: String) throws {
        let data = Data(value.utf8)
        let existing = try read(key)

        if existing != nil {
            let query = baseQuery(for: key)
            let attributes = [kSecValueData as String: data]
            let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            guard status == errSecSuccess else {
                throw SecureStoreError.unhandled(status: status)
            }
        } else {
            var query = baseQuery(for: key)
            query[kSecValueData as String] = data
            let status = SecItemAdd(query as CFDictionary, nil)
            guard status == errSecSuccess else {
                throw SecureStoreError.unhandled(status: status)
            }
        }
    }

    func delete(_ key: String) throws {
        let query = baseQuery(for: key)
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecureStoreError.unhandled(status: status)
        }
    }

    private func baseQuery(for key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
    }
}
