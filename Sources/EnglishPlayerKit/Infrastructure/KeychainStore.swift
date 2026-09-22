import Foundation
import Security

protocol CredentialStoring: AnyObject {
    func set(_ value: String, account: String) throws
    func string(account: String) throws -> String?
    func remove(account: String) throws
}

/// 网盘 access_token / refresh_token / App Key 只进钥匙串，不写数据库、不写配置文件。
final class KeychainStore: CredentialStoring {
    let service: String

    init(service: String = "com.englishplayer.credentials") {
        self.service = service
    }

    func set(_ value: String, account: String) throws {
        try remove(account: account)
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw PlayerError.database("钥匙串写入失败（\(status)）")
        }
    }

    func string(account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw PlayerError.database("钥匙串读取失败（\(status)）")
        }
        return String(data: data, encoding: .utf8)
    }

    func remove(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw PlayerError.database("钥匙串删除失败（\(status)）")
        }
    }
}

final class MemoryCredentialStore: CredentialStoring {
    private var values: [String: String] = [:]

    func set(_ value: String, account: String) throws {
        values[account] = value
    }

    func string(account: String) throws -> String? {
        values[account]
    }

    func remove(account: String) throws {
        values.removeValue(forKey: account)
    }
}
