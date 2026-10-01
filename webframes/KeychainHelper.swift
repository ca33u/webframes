import Foundation
import os
import Security

/// Thin wrapper around macOS Keychain Services for storing sensitive tokens.
///
/// Every operation returns a `Result` carrying an explicit `KeychainError`
/// on failure. OSStatus codes are logged via `Log.keychain` alongside the
/// Security framework's human-readable message so timeouts/sandbox issues
/// can be distinguished from real Keychain errors.
nonisolated enum KeychainHelper {

    private static let service = "pro.webframes.app"

    enum KeychainError: Error, CustomStringConvertible {
        case osStatus(OSStatus, operation: String)
        case invalidUTF8
        case missingItem

        var description: String {
            switch self {
            case .osStatus(let status, let op):
                let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown error"
                return "\(op) failed: OSStatus \(status) (\(message))"
            case .invalidUTF8:
                return "value is not valid UTF-8"
            case .missingItem:
                return "item not found"
            }
        }
    }

    // MARK: - Save

    @discardableResult
    static func save(key: String, value: String) -> Result<Void, KeychainError> {
        guard let data = value.data(using: .utf8) else {
            Log.keychain.error("save \(key, privacy: .public): invalid UTF-8")
            return .failure(.invalidUTF8)
        }
        // Update in place so a failed replacement never deletes a working key.
        let match: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        let updated = SecItemUpdate(match as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updated == errSecSuccess { return .success(()) }
        guard updated == errSecItemNotFound else { return .failure(.osStatus(updated, operation: "save")) }

        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String:   data,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            Log.keychain.error("save \(key, privacy: .public) failed: OSStatus \(status)")
            return .failure(.osStatus(status, operation: "save"))
        }
        Log.keychain.debug("save \(key, privacy: .public): ok (\(data.count) bytes)")
        return .success(())
    }

    /// Inspect presence without retrieving the secret into the settings UI.
    static func contains(key: String) -> Result<Bool, KeychainError> {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        switch status {
        case errSecSuccess: return .success(true)
        case errSecItemNotFound: return .success(false)
        default: return .failure(.osStatus(status, operation: "check"))
        }
    }

    // MARK: - Load

    static func load(key: String) -> Result<String, KeychainError> {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            guard let data = item as? Data,
                  let string = String(data: data, encoding: .utf8) else {
                Log.keychain.error("load \(key, privacy: .public): stored value is not UTF-8")
                return .failure(.invalidUTF8)
            }
            Log.keychain.debug("load \(key, privacy: .public): ok (\(data.count) bytes)")
            return .success(string)

        case errSecItemNotFound:
            // Not an error from the caller's perspective — just absent.
            Log.keychain.debug("load \(key, privacy: .public): not found")
            return .failure(.missingItem)

        default:
            Log.keychain.error("load \(key, privacy: .public) failed: OSStatus \(status)")
            return .failure(.osStatus(status, operation: "load"))
        }
    }

    // MARK: - Delete

    @discardableResult
    static func delete(key: String) -> Result<Void, KeychainError> {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        let status = SecItemDelete(query as CFDictionary)
        switch status {
        case errSecSuccess, errSecItemNotFound:
            Log.keychain.debug("delete \(key, privacy: .public): ok (status \(status))")
            return .success(())
        default:
            Log.keychain.error("delete \(key, privacy: .public) failed: OSStatus \(status)")
            return .failure(.osStatus(status, operation: "delete"))
        }
    }
}
