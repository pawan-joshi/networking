@preconcurrency import Foundation
import Security

/// `TokenStorage` backed by the iOS Keychain.
///
/// The token is JSON-encoded and stored as a generic password item. The item
/// is scoped to a `service` (typically the app's bundle identifier) and an
/// `account` (defaults to `"auth.token"`). Items are protected with
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, which is the standard
/// recommendation for credentials that should not be migrated via iCloud
/// Keychain backups.
public struct KeychainTokenStorage: TokenStorage {
    public let service: String
    public let account: String
    public let accessGroup: String?
    public let accessibility: CFString

    public init(
        service: String,
        account: String = "auth.token",
        accessGroup: String? = nil,
        accessibility: CFString = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    ) {
        self.service = service
        self.account = account
        self.accessGroup = accessGroup
        self.accessibility = accessibility
    }

    public func loadToken() throws -> Token? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecItemNotFound:
            return nil
        case errSecSuccess:
            guard let data = item as? Data else { return nil }
            do {
                return try JSONDecoder().decode(Token.self, from: data)
            } catch {
                throw TokenProviderError.storageFailed(error)
            }
        default:
            throw TokenProviderError.storageFailed(KeychainError(status: status))
        }
    }

    public func save(_ token: Token) throws {
        let data: Data
        do {
            data = try JSONEncoder().encode(token)
        } catch {
            throw TokenProviderError.storageFailed(error)
        }

        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: accessibility,
        ]

        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var addQuery = baseQuery
            for (key, value) in attributes { addQuery[key] = value }
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw TokenProviderError.storageFailed(KeychainError(status: addStatus))
            }
        default:
            throw TokenProviderError.storageFailed(KeychainError(status: updateStatus))
        }
    }

    public func deleteToken() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw TokenProviderError.storageFailed(KeychainError(status: status))
        }
    }

    // MARK: - Private

    private var baseQuery: [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }
}

/// Wraps a non-zero `OSStatus` returned by Security framework calls so the
/// failure surfaces a human-readable message in `TokenProviderError`.
public struct KeychainError: Error, LocalizedError, Sendable, Equatable {
    public let status: OSStatus

    public init(status: OSStatus) {
        self.status = status
    }

    public var errorDescription: String? {
        let message = SecCopyErrorMessageString(status, nil) as String?
        return message ?? "Keychain error \(status)"
    }
}
