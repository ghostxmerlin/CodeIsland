import Foundation
import LocalAuthentication
import Security

enum UnlockPasswordStoreError: Error, Equatable {
    case missing
    case keychain(OSStatus)
}

/// The login password for fingerprint unlock, in the login keychain under
/// AISM's own item. Never validated on save, never read with UI.
enum UnlockPasswordStore {
    static let service = "com.codeisland.app.fingerprint-unlock.password"
    private static let label = "AISM fingerprint unlock (test) — login password"

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: NSUserName()]
    }

    static func save(_ password: String) throws {
        var data = Data(password.utf8)
        defer { data.resetBytes(in: 0..<data.count) }
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw UnlockPasswordStoreError.keychain(update) }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrLabel as String] = label
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw UnlockPasswordStoreError.keychain(status) }
    }

    /// The caller must zero the returned bytes as soon as it is done.
    static func read() throws -> Data {
        var item = query
        item[kSecReturnData as String] = true
        item[kSecMatchLimit as String] = kSecMatchLimitOne
        // Never prompt: a locked keychain fails instead of asking the user.
        let context = LAContext()
        context.interactionNotAllowed = true
        item[kSecUseAuthenticationContext as String] = context
        var result: CFTypeRef?
        let status = SecItemCopyMatching(item as CFDictionary, &result)
        if status == errSecItemNotFound { throw UnlockPasswordStoreError.missing }
        guard status == errSecSuccess else { throw UnlockPasswordStoreError.keychain(status) }
        guard let data = result as? Data, !data.isEmpty else { throw UnlockPasswordStoreError.missing }
        return data
    }

    static func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw UnlockPasswordStoreError.keychain(status)
        }
    }

    /// Looks the item up without reading the secret.
    static func hasPassword() -> Bool {
        var item = query
        item[kSecReturnAttributes as String] = true
        item[kSecMatchLimit as String] = kSecMatchLimitOne
        let context = LAContext()
        context.interactionNotAllowed = true
        item[kSecUseAuthenticationContext as String] = context
        return SecItemCopyMatching(item as CFDictionary, nil) == errSecSuccess
    }
}
