#if os(macOS)
import Foundation
import Security

/// 小雅 / AList 登录凭据。
struct AlistCredential: Codable, Equatable {
    let username: String
    let password: String
}

enum AlistCredentialStoreError: LocalizedError {
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .keychain(let status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "未知错误"
            return "Keychain 访问失败：\(message)（\(status)）"
        }
    }
}

/// 凭据只保存在 macOS Keychain，不写入配置文件或 UserDefaults。
enum AlistCredentialStore {
    private static let service = "com.tvbox.app.macos.alist"
    private static let account = "default"

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false
        ]
    }

    static func loadCredential() throws -> AlistCredential? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw AlistCredentialStoreError.keychain(status)
        }
        guard let data = item as? Data,
              let credential = try? JSONDecoder().decode(AlistCredential.self, from: data),
              !credential.username.isEmpty,
              !credential.password.isEmpty else {
            return nil
        }
        return credential
    }

    static func load() -> AlistCredential? {
        try? loadCredential()
    }

    static func save(username: String, password: String) throws {
        let credential = AlistCredential(username: username, password: password)
        let data = try JSONEncoder().encode(credential)

        let updateStatus = SecItemUpdate(
            baseQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw AlistCredentialStoreError.keychain(updateStatus)
        }

        var item = baseQuery
        item[kSecValueData as String] = data
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw AlistCredentialStoreError.keychain(addStatus)
        }
    }

    static func delete() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}
#endif
