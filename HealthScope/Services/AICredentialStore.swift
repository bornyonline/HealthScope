import Foundation
import Security

struct AICredentialStore {
    private let service: String
    private let account = "unsloth-bearer-api-key"

    init(service: String = (Bundle.main.bundleIdentifier ?? "HealthScope") + ".ai-credentials") {
        self.service = service
    }

    func loadUnslothAPIKey() throws -> String {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess,
              let data = result as? Data,
              let key = String(data: data, encoding: .utf8) else {
            throw AICredentialStoreError.keychain(status)
        }
        return key
    }

    func saveUnslothAPIKey(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.rangeOfCharacter(from: .newlines) == nil else {
            throw AICredentialStoreError.invalidKey
        }
        if trimmed.isEmpty {
            let status = SecItemDelete(baseQuery as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw AICredentialStoreError.keychain(status)
            }
            return
        }

        let attributes: [String: Any] = [
            kSecValueData as String: Data(trimmed.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw AICredentialStoreError.keychain(updateStatus)
        }

        var newItem = baseQuery
        attributes.forEach { newItem[$0.key] = $0.value }
        let status = SecItemAdd(newItem as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw AICredentialStoreError.keychain(status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

enum AICredentialStoreError: LocalizedError {
    case keychain(OSStatus)
    case invalidKey

    var errorDescription: String? {
        switch self {
        case .keychain(let status):
            let detail = SecCopyErrorMessageString(status, nil) as String? ?? "status \(status)"
            return "Unable to access the Unsloth API key in Keychain: \(detail)"
        case .invalidKey:
            return "The Unsloth API key cannot contain line breaks."
        }
    }
}
