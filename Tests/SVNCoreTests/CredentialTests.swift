import XCTest
@testable import SVNCore

private final class TestVault: CredentialVault, @unchecked Sendable {
    var passwords: [String: String] = [:]
    var failWrite = false
    var failRead = false
    func read(id: String) throws -> String {
        guard !failRead, let password = passwords[id] else { throw SVNFailure("测试：密码不可用") }
        return password
    }
    func write(id: String, password: String, label: String) throws {
        if failWrite { throw SVNFailure("测试：钥匙串写入失败") }
        passwords[id] = password
    }
    func delete(id: String) throws { passwords.removeValue(forKey: id) }
}

final class CredentialTests: XCTestCase {
    func testPersistenceSelectionEditingAndDeletion() async throws {
        let suite = "svndesk-credential-tests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let vault = TestVault()
        // 使用共享密码库模拟重启，配置与密码存储保持分离。
        let firstStore = CredentialStore(defaults: defaults, vault: vault)
        let first = try await firstStore.save(id: nil, name: "公司 SVN", username: "account-one", password: "dummy-secret-one")
        let firstID = try XCTUnwrap(first.configuration.selectedID)
        let second = try await firstStore.save(id: nil, name: "测试 SVN", username: "account-two", password: "dummy-secret-two")
        let secondID = try XCTUnwrap(second.configuration.selectedID)
        let relaunched = CredentialStore(defaults: defaults, vault: vault)
        let restored = try await relaunched.restore()
        XCTAssertEqual(restored.configuration.profiles.count, 2)
        XCTAssertEqual(restored.configuration.selectedID, secondID)
        XCTAssertEqual(restored.credentials.username, "account-two")
        XCTAssertEqual(restored.credentials.password, "dummy-secret-two")
        let selected = try await relaunched.select(firstID)
        XCTAssertEqual(selected.credentials.username, "account-one")
        let edited = try await relaunched.save(id: firstID, name: "正式 SVN", username: "renamed-account", password: "")
        XCTAssertEqual(edited.credentials.password, "dummy-secret-one")
        XCTAssertEqual(edited.configuration.profiles.count, 2)
        let encoded = String(decoding: try XCTUnwrap(defaults.data(forKey: "credentialConfiguration")), as: UTF8.self)
        XCTAssertTrue(encoded.contains("正式 SVN")); XCTAssertFalse(encoded.contains("dummy-secret")); XCTAssertFalse(encoded.contains("password"))
        let removed = try await relaunched.delete(firstID)
        XCTAssertNil(removed.configuration.selectedID)
        XCTAssertEqual(removed.credentials.username, "")
        XCTAssertNil(vault.passwords[firstID]); XCTAssertNotNil(vault.passwords[secondID])
        _ = try await relaunched.select(secondID)
        let automatic = try await relaunched.select(nil)
        XCTAssertNil(automatic.configuration.selectedID); XCTAssertEqual(automatic.credentials.password, "")
    }

    func testVaultFailuresKeepConfigurationAndSelection() async throws {
        let suite = "svndesk-credential-failure-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let vault = TestVault(), store = CredentialStore(defaults: defaults, vault: vault)
        let saved = try await store.save(id: nil, name: "可用凭据", username: "test", password: "dummy-secret")
        let id = try XCTUnwrap(saved.configuration.selectedID)
        let original = defaults.data(forKey: "credentialConfiguration")
        vault.failWrite = true
        do {
            _ = try await store.save(id: id, name: "不能写入", username: "changed", password: "new-dummy")
            XCTFail("钥匙串失败时不应保存成功")
        } catch {}
        XCTAssertEqual(defaults.data(forKey: "credentialConfiguration"), original)
        XCTAssertEqual(vault.passwords[id], "dummy-secret")
        vault.failRead = true
        do { _ = try await store.select(id); XCTFail("密码读取失败时不应切换成功") } catch {}
        XCTAssertEqual(defaults.data(forKey: "credentialConfiguration"), original)
        vault.failRead = false
        do { _ = try await store.save(id: nil, name: "未填写密码", username: "test", password: ""); XCTFail("新增应要求密码") } catch {}
        XCTAssertEqual(defaults.data(forKey: "credentialConfiguration"), original)
        defaults.set(Data("损坏配置".utf8), forKey: "credentialConfiguration")
        do { _ = try await store.restore(); XCTFail("损坏配置应报错") } catch {}
        XCTAssertEqual(defaults.data(forKey: "credentialConfiguration"), Data("损坏配置".utf8))
    }

    func testRealKeychainWriteUpdateReadAndDelete() async throws {
        let vault = KeychainCredentialVault(service: "net.wologic.svndesk.tests." + UUID().uuidString)
        let id = UUID().uuidString
        defer { try? vault.delete(id: id) }
        try vault.write(id: id, password: "dummy-one", label: "自动化验证")
        XCTAssertEqual(try vault.read(id: id), "dummy-one")
        try vault.write(id: id, password: "dummy-two", label: "自动化验证更新")
        XCTAssertEqual(try vault.read(id: id), "dummy-two")
        try vault.delete(id: id)
        XCTAssertThrowsError(try vault.read(id: id))
        XCTAssertNoThrow(try vault.delete(id: id))
    }
}
