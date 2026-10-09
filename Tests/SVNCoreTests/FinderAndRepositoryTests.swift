import XCTest
@testable import SVNCore

final class FinderAndRepositoryTests: XCTestCase {
    func testReadableURLPreservesEncodedPathMeaning() throws {
        for raw in [
            "https://example.com/svn/%E4%B8%AD%E6%96%87%20%40%23%25%2F%3F",
            "file:///tmp/%E4%BB%93%E5%BA%93%20%40",
            "svn+ssh://example.com/%F0%9F%93%81/%E6%A8%A1%E5%9D%97"
        ] {
            let url = try SVNRepository.validate(raw)
            let displayed = SVNRepository.displayURL(url)
            XCTAssertFalse(displayed.contains("%E4"))
            XCTAssertEqual(try SVNRepository.validate(displayed).absoluteString, url.absoluteString)
        }
        let url = try SVNRepository.validate("https://example.com/%E4%B8%AD%E6%96%87%23%25%2F%3F")
        XCTAssertEqual(SVNRepository.displayURL(url), "https://example.com/中文%23%25%2F%3F")
    }
    func testFinderBadgesAndRequests() throws {
        let xml = """
        <status><target path=".">
        <entry path="src/中文 @.txt"><wc-status item="modified" props="none"/></entry>
        <entry path="src/冲突.txt"><wc-status item="conflicted" props="none"/></entry>
        <entry path="新文件"><wc-status item="added" props="none"/></entry>
        <entry path="未跟踪"><wc-status item="unversioned" props="none"/></entry>
        <entry path="忽略"><wc-status item="ignored" props="none"/></entry>
        <entry path="../外部路径"><wc-status item="modified" props="none"/></entry>
        </target></status>
        """
        let root = FinderRootState(path: "/项目", entries: try SVNParser.status(Data(xml.utf8)))
        let snapshot = FinderSnapshot(roots: [root])
        XCTAssertEqual(snapshot.badge(for: "/项目/src/中文 @.txt"), .modified)
        XCTAssertEqual(snapshot.badge(for: "/项目/src"), .conflict)
        XCTAssertEqual(snapshot.badge(for: "/项目"), .conflict)
        XCTAssertEqual(snapshot.badge(for: "/项目/新文件"), .added)
        XCTAssertEqual(snapshot.badge(for: "/项目/未跟踪"), .unversioned)
        XCTAssertNil(snapshot.badge(for: "/项目/忽略"))
        XCTAssertNil(snapshot.badge(for: "/项目-另一个/src"))
        XCTAssertNil(snapshot.badge(for: "/外部路径"))
        XCTAssertNil(snapshot.badge(for: "/项目", now: Date().addingTimeInterval(21)))
        XCTAssertNil(FinderSnapshot(roots: [.init(path: "/项目", entries: nil)]).badge(for: "/项目"))
        let request = FinderRequest(action: "diff", paths: ["/项目/中文 @ # &.txt"])
        let decoded = try XCTUnwrap(FinderRequest.parse(XCTUnwrap(request.url)))
        XCTAssertEqual(decoded.paths, request.paths)
        XCTAssertEqual(decoded.action, "diff")
        XCTAssertNil(FinderRequest.parse(URL(string: "svndesk://finder?action=destroy&path=/项目")!))
        XCTAssertNil(FinderRequest.parse(URL(string: "svndesk://finder?action=update&path=relative")!))
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("finder-snapshot-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temp) }
        let file = temp.appendingPathComponent("state.json")
        try snapshot.write(to: file)
        XCTAssertEqual(try FinderSnapshot.read(from: file).badge(for: "/项目/src"), .conflict)
    }

    func testBrowseThenCheckoutSelectedDirectoryAtHistoricalRevision() async throws {
        guard SVNClient.executable() != nil else { throw XCTSkip("本机未安装 SVN") }
        let admin = "/opt/homebrew/bin/svnadmin"
        guard FileManager.default.isExecutableFile(atPath: admin) else { throw XCTSkip("本机未安装 svnadmin") }
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("svndesk-browser-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let repo = base.appendingPathComponent("仓库 @"), seed = base.appendingPathComponent("种子"), wc = base.appendingPathComponent("完整工作副本"), checkout = base.appendingPathComponent("指定检出目录")
        let process = Process(); process.executableURL = URL(fileURLWithPath: admin); process.arguments = ["create", repo.path]
        try process.run(); process.waitUntilExit(); XCTAssertEqual(process.terminationStatus, 0)
        try FileManager.default.createDirectory(at: seed.appendingPathComponent("trunk/模块 @"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: seed.appendingPathComponent("branches"), withIntermediateDirectories: true)
        try "name = original\n// 原始版本\n".write(to: seed.appendingPathComponent("trunk/模块 @/中文 @.txt"), atomically: true, encoding: .utf8)
        let client = SVNClient()
        _ = try await client.run(["import", seed.path, repo.absoluteString, "-m", "建立目录结构"])
        _ = try await client.run(["checkout", "--", repo.absoluteString + "@", wc.path])
        try "name = changed\n// 最新版本\n".write(to: wc.appendingPathComponent("trunk/模块 @/中文 @.txt"), atomically: true, encoding: .utf8)
        _ = try await client.run(["commit", "-m", "更新文件", "--", ".@"], directory: wc.path)
        let remote = try SVNRepository.validate(repo.absoluteString)
        let rootItems = try SVNRepository.parse(await client.run(["list", "--xml", "-r", "HEAD", "--", SVNRepository.target(remote, revision: "HEAD")]))
        XCTAssertEqual(rootItems.map(\.name), ["branches", "trunk"])
        XCTAssertTrue(rootItems.allSatisfy(\.isDirectory))
        let module = remote.appendingPathComponent("trunk").appendingPathComponent("模块 @")
        let items = try SVNRepository.parse(await client.run(["list", "--xml", "-r", "1", "--", SVNRepository.target(module, revision: "1")]))
        XCTAssertEqual(items.first?.name, "中文 @.txt")
        XCTAssertEqual(items.first?.revision, "1")
        XCTAssertFalse(try XCTUnwrap(items.first).isDirectory)
        let preview = try await client.run(["cat", "-r", "1", "--", SVNRepository.target(module.appendingPathComponent("中文 @.txt"), revision: "1")])
        XCTAssertTrue(String(decoding: preview, as: UTF8.self).contains("原始版本"))
        _ = try await client.run(["checkout", "-r", "1", "--", SVNRepository.target(module, revision: "1"), checkout.path])
        XCTAssertTrue(try String(contentsOf: checkout.appendingPathComponent("中文 @.txt"), encoding: .utf8).contains("原始版本"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: checkout.appendingPathComponent("branches").path))
        let info = try await client.info(at: checkout.path)
        XCTAssertEqual(info.revision, "1"); XCTAssertEqual(info.kind, "dir")
        XCTAssertTrue(SVNRepository.contains(module, in: remote))
        XCTAssertFalse(SVNRepository.contains(URL(string: "https://other.example.com/repo")!, in: remote))
        XCTAssertThrowsError(try SVNRepository.validate("https://user:secret@example.com/repo"))
        XCTAssertThrowsError(try SVNRepository.revision("-1"))
    }
}
