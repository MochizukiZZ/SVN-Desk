import XCTest
@testable import SVNCore

final class SVNCoreTests: XCTestCase {
    func testXMLHandlesUnicodePropertiesAndTreeConflicts() throws {
        let xml = """
        <?xml version="1.0"?><status><target path=".">
        <entry path="目录/中文 空格@.txt"><wc-status item="modified" props="none" revision="42"><commit revision="40"><author>作者</author></commit></wc-status></entry>
        <entry path="属性.txt"><wc-status item="normal" props="modified" revision="42"/></entry>
        <entry path="树冲突"><wc-status item="normal" props="none" tree-conflicted="true" revision="42"/></entry>
        <entry path="属性冲突"><wc-status item="normal" props="conflicted" revision="42"/></entry>
        </target></status>
        """
        let entries = try SVNParser.status(Data(xml.utf8))
        XCTAssertEqual(entries[0].path, "目录/中文 空格@.txt")
        XCTAssertEqual(entries[0].revision, "42")
        XCTAssertTrue(entries[1].canCommit)
        XCTAssertTrue(entries[2].isConflict)
        XCTAssertFalse(entries[2].canCommit)
        XCTAssertTrue(entries[3].isConflict)
        XCTAssertThrowsError(try SVNParser.status(Data("<invalid>".utf8)))
        XCTAssertEqual(SVNClient.target("-名称@.txt"), "./-名称@.txt@")
    }

    func testCancellationAndCredentialTransport() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("svndesk-process-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let fake = base.appendingPathComponent("fake-svn")
        let script = "#!/bin/zsh\nif [[ $* == *slow* ]]; then\n  trap 'exit 130' INT\n  for i in {1..30}; do /bin/sleep 0.1; done\n  exit 0\nfi\nread -r secret\nprint -r -- \"$*\"\n[[ $secret == transport-test ]] && print stdin-ok\n"
        try script.write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake.path)
        let client = SVNClient()
        let output = try await client.run(["inspect"], executable: fake.path, credentials: .init(username: "tester", password: "transport-test"))
        let text = String(decoding: output, as: UTF8.self)
        XCTAssertTrue(text.contains("--password-from-stdin"))
        XCTAssertTrue(text.contains("--no-auth-cache"))
        XCTAssertTrue(text.contains("stdin-ok"))
        XCTAssertFalse(text.contains("transport-test"), "密码不得出现在进程参数中")
        let operation = Task { try await client.run(["slow"], executable: fake.path) }
        try await Task.sleep(nanoseconds: 200_000_000)
        client.cancelAll()
        do { _ = try await operation.value; XCTFail("取消操作必须返回错误") }
        catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
    }

    func testRealRepositoryWorkflow() async throws {
        guard let svn = SVNClient.executable(), let admin = ["/opt/homebrew/bin/svnadmin", "/usr/local/bin/svnadmin"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { throw XCTSkip("本机未安装 SVN") }
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("SVNDesk 测试 " + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let repo = base.appendingPathComponent("仓库"), wc = base.appendingPathComponent("工作 副本@"), other = base.appendingPathComponent("另一副本")
        let create = Process(); create.executableURL = URL(fileURLWithPath: admin); create.arguments = ["create", repo.path]
        try create.run(); create.waitUntilExit(); XCTAssertEqual(create.terminationStatus, 0)
        let client = SVNClient()
        _ = try await client.run(["checkout", "--", repo.absoluteString + "@", wc.path], executable: svn)
        let info = try await client.info(at: wc.path)
        XCTAssertEqual(
            try FileManager.default.attributesOfItem(atPath: info.workingRoot)[.systemFileNumber] as? NSNumber,
            try FileManager.default.attributesOfItem(atPath: wc.path)[.systemFileNumber] as? NSNumber
        )
        XCTAssertEqual(info.revision, "0")
        let a = "中文 空格@名称.txt", b = "-另一个.txt"
        func write(_ name: String, _ text: String, at directory: URL = wc) throws { try text.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        try write(a, "初始内容\n"); try write(b, "保留内容\n")
        var status = try await client.status(at: wc.path)
        XCTAssertEqual(Set(status.map(\.status)), ["unversioned"])
        _ = try await client.run(["add", "--", SVNClient.target(a), SVNClient.target(b)], directory: wc.path)
        _ = try await client.run(["propset", "svn:mime-type", "text/plain", "--", SVNClient.target(a), SVNClient.target(b)], directory: wc.path)
        _ = try await client.run(["commit", "--depth", "empty", "-m", "首次提交", "--", SVNClient.target(a), SVNClient.target(b)], directory: wc.path)
        status = try await client.status(at: wc.path); XCTAssertTrue(status.isEmpty)
        try write(a, "仅提交这一项\n"); try write(b, "此项暂不提交\n")
        let diff = try await client.run(["diff", "--internal-diff", "--old", SVNClient.target(a)], directory: wc.path)
        XCTAssertTrue(String(decoding: diff, as: UTF8.self).contains("+仅提交这一项"), String(decoding: diff, as: UTF8.self))
        _ = try await client.run(["commit", "--depth", "empty", "-m", "选择性提交", "--", SVNClient.target(a)], directory: wc.path)
        status = try await client.status(at: wc.path)
        XCTAssertEqual(status.map(\.path), [b], "未勾选的文件必须保持未提交")
        _ = try await client.run(["revert", "--depth", "infinity", "--", SVNClient.target(b)], directory: wc.path)
        XCTAssertEqual(try String(contentsOf: wc.appendingPathComponent(b), encoding: .utf8), "保留内容\n")
        let log = try SVNParser.logs(await client.run(["log", "--xml", "-v", "-r", "HEAD:1", "--", ".@"], directory: wc.path))
        XCTAssertEqual(log.count, 2); XCTAssertEqual(log[0].message, "选择性提交"); XCTAssertEqual(log[0].paths.count, 1)
        _ = try await client.run(["checkout", "--", repo.absoluteString + "@", other.path])
        _ = try await client.run(["update", "--", ".@"], directory: wc.path)
        try write(a, "本地版本\n"); try write(a, "远程版本\n", at: other)
        _ = try await client.run(["commit", "-m", "远程改动", "--", SVNClient.target(a)], directory: other.path)
        _ = try await client.run(["update", "--", ".@"], directory: wc.path)
        status = try await client.status(at: wc.path)
        XCTAssertTrue(status.contains(where: { $0.path == a && $0.isConflict && !$0.canCommit }))
        try write(a, "手动合并内容\n")
        _ = try await client.run(["resolve", "--accept", "working", "--", SVNClient.target(a)], directory: wc.path)
        status = try await client.status(at: wc.path)
        XCTAssertTrue(status.contains(where: { $0.path == a && $0.canCommit && !$0.isConflict }))
        _ = try await client.run(["revert", "--", SVNClient.target(a)], directory: wc.path)
        try FileManager.default.removeItem(at: wc.appendingPathComponent(b))
        status = try await client.status(at: wc.path); XCTAssertEqual(status.first?.status, "missing")
        _ = try await client.run(["delete", "--", SVNClient.target(b)], directory: wc.path)
        _ = try await client.run(["commit", "--depth", "empty", "-m", "删除缺失文件", "--", SVNClient.target(b)], directory: wc.path)
        let final = try await client.status(at: wc.path); XCTAssertTrue(final.isEmpty)
        // 验证新增目录与子文件可通过显式路径、空递归深度一起提交。
        try FileManager.default.createDirectory(at: wc.appendingPathComponent("新目录"), withIntermediateDirectories: true)
        try write("新目录/子文件.txt", "新增\n")
        _ = try await client.run(["add", "--", SVNClient.target("新目录")], directory: wc.path)
        _ = try await client.run(["commit", "--depth", "empty", "-m", "新增目录", "--", SVNClient.target("新目录"), SVNClient.target("新目录/子文件.txt")], directory: wc.path)
        let clean = try await client.status(at: wc.path); XCTAssertTrue(clean.isEmpty)
        do {
            _ = try await client.run(["info", "--xml", "--", SVNClient.target("不存在")], directory: wc.path)
            XCTFail("非法路径应返回错误")
        } catch { XCTAssertTrue(error.localizedDescription.contains("svn:")) }
    }
}
