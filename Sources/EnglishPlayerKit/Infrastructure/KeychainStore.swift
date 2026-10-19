import Foundation
import Security

protocol CredentialStoring: AnyObject {
    func set(_ value: String, account: String) throws
    func string(account: String) throws -> String?
    func remove(account: String) throws
}

/// 网盘登录信息写在 SQLite 里，打开软件时不再问系统密码。
final class SQLiteCredentialStore: CredentialStoring {
    private let store: SQLiteStore

    init(store: SQLiteStore) {
        self.store = store
    }

    func set(_ value: String, account: String) throws {
        try store.setCredential(account: account, value: value)
    }

    func string(account: String) throws -> String? {
        try store.credential(account: account)
    }

    func remove(account: String) throws {
        try store.removeCredential(account: account)
    }
}

/// 旧的钥匙串实现。正式启动不再使用，避免每次打开都要输入登录密码。
final class KeychainStore: CredentialStoring {
    let service: String
    /// 同一次启动里每条凭据只读一次，避免连续弹多次。
    private var cache: [String: String] = [:]

    init(service: String = "com.englishplayer.credentials") {
        self.service = service
    }

    func set(_ value: String, account: String) throws {
        try remove(account: account)
        try add(value, account: account)
        cache[account] = value
    }

    func string(account: String) throws -> String? {
        if let cached = cache[account] { return cached }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let item else {
            throw PlayerError.database("钥匙串读取失败（\(status)）")
        }
        guard let data = Self.secretData(from: item), let value = String(data: data, encoding: .utf8) else {
            throw PlayerError.database("钥匙串读取失败（\(status)）")
        }
        // swift run 每次都是新的临时签名。旧条目只信任上一次的程序，所以每次启动都要输密码。
        // 读到旧条目后改写成「不按某一次签名来拦」，下一次编译就不再问。
        if Self.comment(from: item) != Self.openAccessMarker {
            markOpen(value, account: account)
        }
        cache[account] = value
        return value
    }

    func remove(account: String) throws {
        cache.removeValue(forKey: account)
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

    private func add(_ value: String, account: String) throws {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecAttrComment as String: Self.openAccessMarker
        ]
        if let access = Self.openAccess() {
            query[kSecAttrAccess as String] = access
        }
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw PlayerError.database("钥匙串写入失败（\(status)）")
        }
    }

    /// 先改原条目的访问权限。改不了再删掉重写，避免凭据在中途丢掉。
    private func markOpen(_ value: String, account: String) {
        var changes: [String: Any] = [
            kSecAttrComment as String: Self.openAccessMarker
        ]
        if let access = Self.openAccess() {
            changes[kSecAttrAccess as String] = access
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        if SecItemUpdate(query as CFDictionary, changes as CFDictionary) == errSecSuccess {
            return
        }
        try? remove(account: account)
        try? add(value, account: account)
    }

    private static let openAccessMarker = "englishplayer-open-access"

    private static func secretData(from item: CFTypeRef) -> Data? {
        if let data = item as? Data { return data }
        guard let dictionary = item as? NSDictionary else { return nil }
        return dictionary[kSecValueData as String] as? Data
    }

    private static func comment(from item: CFTypeRef) -> String? {
        guard let dictionary = item as? NSDictionary else { return nil }
        return dictionary[kSecAttrComment as String] as? String
    }

    /// 临时签名（swift run）在钥匙串看来是「未签名 / 签名无效」。
    /// 默认策略会向这类程序要登录密码。这里明确关掉这两类提示，并且不绑定某一次编译出的程序。
    private static func openAccess() -> SecAccess? {
        var access: SecAccess?
        guard SecAccessCreate("EnglishPlayer" as CFString, nil, &access) == errSecSuccess, let access else {
            return nil
        }
        var list: CFArray?
        guard SecAccessCopyACLList(access, &list) == errSecSuccess, let list else { return access }
        // SecACL.h: unsignedAct = 0x0020，invalidAct = 0x0080。
        // 只置 Act 位、不置「要弹窗」位，临时签名才不会被系统默认策略拦住。
        let prompt = SecKeychainPromptSelector(rawValue: 0x0020 | 0x0080)
        for index in 0..<CFArrayGetCount(list) {
            let raw = CFArrayGetValueAtIndex(list, index)
            let acl = Unmanaged<SecACL>.fromOpaque(raw!).takeUnretainedValue()
            SecACLSetContents(acl, nil, "EnglishPlayer" as CFString, prompt)
        }
        return access
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
