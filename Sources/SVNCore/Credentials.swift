import Foundation
import Security

public struct CredentialProfile: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public var name: String
    public var username: String
}

public struct CredentialConfiguration: Codable, Sendable {
    public var profiles: [CredentialProfile] = []
    public var selectedID: String?
    public init() {}
}

public struct CredentialSelection: Sendable {
    public let configuration: CredentialConfiguration
    public let credentials: SVNCredentials
}

public protocol CredentialVault: Sendable {
    func read(id: String) throws -> String
    func write(id: String, password: String, label: String) throws
    func delete(id: String) throws
}

public struct KeychainCredentialVault: CredentialVault {
    private let service: String
    public init(service: String) { self.service = service }
    private func query(_ id: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: id]
    }
    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            let detail = SecCopyErrorMessageString(status, nil) as String? ?? "错误码 \(status)"
            throw SVNFailure("无法访问 macOS 钥匙串：\(detail)")
        }
    }
    public func read(id: String) throws -> String {
        var request = query(id)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { throw SVNFailure("该凭据的密码已从钥匙串移除，请重新填写密码并保存。") }
        try check(status)
        guard let data = result as? Data, let password = String(data: data, encoding: .utf8) else {
            throw SVNFailure("钥匙串中的密码格式无效，请重新保存凭据。")
        }
        return password
    }
    public func write(id: String, password: String, label: String) throws {
        let attributes: [String: Any] = [kSecValueData as String: Data(password.utf8), kSecAttrLabel as String: "SVN Desk · " + label]
        let request = query(id)
        let status = SecItemUpdate(request as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            try check(SecItemAdd(request.merging(attributes) { _, new in new } as CFDictionary, nil))
        } else { try check(status) }
    }
    public func delete(id: String) throws {
        let status = SecItemDelete(query(id) as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }
}

// 所有钥匙串调用在独立 actor 中执行，避免权限询问阻塞主界面。
public actor CredentialStore {
    private let defaults: UserDefaults
    private let vault: any CredentialVault
    private let key = "credentialConfiguration"
    public init(defaults: UserDefaults = .standard, vault: any CredentialVault) {
        self.defaults = defaults; self.vault = vault
    }
    public func configuration() throws -> CredentialConfiguration {
        guard let data = defaults.data(forKey: key) else { return .init() }
        guard let value = try? JSONDecoder().decode(CredentialConfiguration.self, from: data),
              Set(value.profiles.map(\.id)).count == value.profiles.count,
              value.selectedID == nil || value.profiles.contains(where: { $0.id == value.selectedID }) else {
            throw SVNFailure("已保存的凭据配置无法读取，请检查应用配置；现有配置未被覆盖。")
        }
        return value
    }
    private func persist(_ configuration: CredentialConfiguration) throws {
        defaults.set(try JSONEncoder().encode(configuration), forKey: key)
    }
    private func credentials(_ configuration: CredentialConfiguration) throws -> SVNCredentials {
        guard let id = configuration.selectedID, let profile = configuration.profiles.first(where: { $0.id == id }) else { return .init() }
        return .init(username: profile.username, password: try vault.read(id: id))
    }
    public func restore() throws -> CredentialSelection {
        let value = try configuration()
        return .init(configuration: value, credentials: try credentials(value))
    }
    public func select(_ id: String?) throws -> CredentialSelection {
        var value = try configuration()
        guard id == nil || value.profiles.contains(where: { $0.id == id }) else { throw SVNFailure("所选凭据不存在。") }
        value.selectedID = id
        let loaded = try credentials(value)
        try persist(value)
        return .init(configuration: value, credentials: loaded)
    }
    public func save(id: String?, name: String, username: String, password: String) throws -> CredentialSelection {
        var value = try configuration()
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !username.isEmpty else { throw SVNFailure("请填写凭据名称和用户名。") }
        guard !username.contains("\n"), !username.contains("\0"), !password.contains("\n"), !password.contains("\r"), !password.contains("\0") else {
            throw SVNFailure("用户名或密码不能包含换行或空字符。")
        }
        if let id, !value.profiles.contains(where: { $0.id == id }) { throw SVNFailure("要修改的凭据不存在。") }
        let identifier = id ?? UUID().uuidString
        let storedPassword = password.isEmpty && id != nil ? try vault.read(id: identifier) : password
        guard !storedPassword.isEmpty else { throw SVNFailure("新增凭据需要填写密码。") }
        let profile = CredentialProfile(id: identifier, name: name, username: username)
        try vault.write(id: identifier, password: storedPassword, label: name)
        if let index = value.profiles.firstIndex(where: { $0.id == identifier }) { value.profiles[index] = profile }
        else { value.profiles.append(profile) }
        value.selectedID = identifier
        try persist(value)
        return .init(configuration: value, credentials: .init(username: username, password: storedPassword))
    }
    public func delete(_ id: String) throws -> CredentialSelection {
        var value = try configuration()
        guard value.profiles.contains(where: { $0.id == id }) else { throw SVNFailure("要删除的凭据不存在。") }
        // 先确认当前选择可用，钥匙串失败时不修改配置或删除其它凭据。
        if value.selectedID == id { value.selectedID = nil }
        let loaded = try credentials(value)
        try vault.delete(id: id)
        value.profiles.removeAll { $0.id == id }
        try persist(value)
        return .init(configuration: value, credentials: loaded)
    }
}
