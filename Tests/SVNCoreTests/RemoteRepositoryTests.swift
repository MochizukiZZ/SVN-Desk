import XCTest
@testable import SVNCore

final class RemoteRepositoryTests: XCTestCase {
    private func fixture() throws -> (URL, URL, String) {
        guard let svn = SVNClient.executable(), let mucc = SVNRemoteMutation.executable(svn: svn) else { throw XCTSkip("本机未安装 Subversion 与 svnmucc") }
        let admin = URL(fileURLWithPath: svn).deletingLastPathComponent().appendingPathComponent("svnadmin")
        guard FileManager.default.isExecutableFile(atPath: admin.path) else { throw XCTSkip("本机未安装 svnadmin") }
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("svndesk-remote-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let repository = base.appendingPathComponent("仓库 @")
        let process = Process(); process.executableURL = admin; process.arguments = ["create", repository.path]
        try process.run(); process.waitUntilExit(); XCTAssertEqual(process.terminationStatus, 0)
        return (base, repository, mucc)
    }
    private func list(_ directory: URL, client: SVNClient) async throws -> [SVNRepositoryItem] {
        try SVNRepository.parse(await client.run(["list", "--xml", "-r", "HEAD", "--", SVNRepository.target(directory, revision: "HEAD")]))
    }
    private func cat(_ file: URL, revision: String = "HEAD", client: SVNClient) async throws -> String {
        String(decoding: try await client.run(["cat", "-r", revision, "--", SVNRepository.target(file, revision: revision)]), as: UTF8.self)
    }

    func testDirectUploadOverwriteRenameDeleteAndDatesWithoutCheckout() async throws {
        let (base, repository, mucc) = try fixture()
        defer { try? FileManager.default.removeItem(at: base) }
        let client = SVNClient(), directory = try SVNRemoteMutation.child("项目 @ #", in: repository)
        let create = try SVNRemoteMutation.createDirectory(name: "项目 @ #", directory: repository, existing: [])
        _ = try await SVNRemoteMutation.commit(create, directory: repository, revision: "0", message: "新建项目", client: client, executable: mucc)
        let source = base.appendingPathComponent("数据 @ #.txt"), tree = base.appendingPathComponent("目录 @")
        try "first version\n".write(to: source, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: tree.appendingPathComponent("空目录"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tree.appendingPathComponent(".svn"), withIntermediateDirectories: true)
        try "不应上传".write(to: tree.appendingPathComponent(".svn/entries"), atomically: true, encoding: .utf8)
        try "ignored".write(to: tree.appendingPathComponent(".DS_Store"), atomically: true, encoding: .utf8)
        try "nested content".write(to: tree.appendingPathComponent("文件 @.txt"), atomically: true, encoding: .utf8)
        let upload = try SVNRemoteMutation.upload(sources: [source, tree], directory: directory, existing: [], overwrite: false)
        XCTAssertEqual(upload.fileCount, 2); XCTAssertEqual(upload.directoryCount, 2)
        _ = try await SVNRemoteMutation.commit(upload, directory: directory, revision: "1", message: "一次上传文件与目录", client: client, executable: mucc)
        var items = try await list(directory, client: client)
        XCTAssertEqual(Set(items.map(\.name)), ["数据 @ #.txt", "目录 @"])
        let uploadedTree = directory.appendingPathComponent("目录 @")
        let nested = try await list(uploadedTree, client: client)
        XCTAssertEqual(Set(nested.map(\.name)), ["空目录", "文件 @.txt"])
        let originalURL = directory.appendingPathComponent(source.lastPathComponent)
        let created = try await SVNRepository.creationRecord(for: originalURL, revision: "2", client: client)
        XCTAssertEqual(created?.revision, "2"); XCTAssertFalse(SVNRepository.displayDate(created?.date ?? "").contains("—"))
        XCTAssertThrowsError(try SVNRemoteMutation.upload(sources: [source], directory: directory, existing: items, overwrite: false))
        try "second version\n".write(to: source, atomically: true, encoding: .utf8)
        let overwrite = try SVNRemoteMutation.upload(sources: [source], directory: directory, existing: items, overwrite: true)
        _ = try await SVNRemoteMutation.commit(overwrite, directory: directory, revision: "2", message: "覆盖同名文件", client: client, executable: mucc)
        let updated = try await cat(originalURL, client: client)
        XCTAssertEqual(updated, "second version\n")
        items = try await list(directory, client: client)
        let file = try XCTUnwrap(items.first { !$0.isDirectory })
        XCTAssertEqual(file.revision, "3"); XCTAssertFalse(file.date.isEmpty)
        let preservedCreation = try await SVNRepository.creationRecord(for: originalURL, revision: "3", client: client)
        XCTAssertEqual(preservedCreation?.date, created?.date)
        let renamedURL = directory.appendingPathComponent("重命名 @ #.txt")
        let rename = try SVNRemoteMutation.rename(item: file, name: renamedURL.lastPathComponent, directory: directory, existing: items)
        _ = try await SVNRemoteMutation.commit(rename, directory: directory, revision: "3", message: "重命名文件", client: client, executable: mucc)
        let renamed = try await cat(renamedURL, client: client)
        XCTAssertEqual(renamed, "second version\n")
        let renamedCreation = try await SVNRepository.creationRecord(for: renamedURL, revision: "4", client: client)
        XCTAssertEqual(renamedCreation?.revision, "4")
        let folder = try XCTUnwrap(items.first { $0.isDirectory })
        let remove = try SVNRemoteMutation.delete(item: folder, directory: directory)
        _ = try await SVNRemoteMutation.commit(remove, directory: directory, revision: "4", message: "删除整个目录", client: client, executable: mucc)
        let final = try await list(directory, client: client)
        XCTAssertEqual(final.map(\.name), [renamedURL.lastPathComponent])
        let historical = try await cat(uploadedTree.appendingPathComponent("文件 @.txt"), revision: "2", client: client)
        XCTAssertEqual(historical, "nested content")
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.appendingPathComponent(".svn").path))
        let head = try SVNParser.info(await client.run(["info", "--xml", "-r", "HEAD", "--", repository.absoluteString + "@HEAD"]))
        XCTAssertEqual(head.revision, "5")
    }

    func testStaleRevisionRejectsAllActionsAtomically() async throws {
        let (base, repository, mucc) = try fixture()
        defer { try? FileManager.default.removeItem(at: base) }
        let client = SVNClient(), first = base.appendingPathComponent("first.txt"), second = base.appendingPathComponent("second.txt")
        try "initial".write(to: first, atomically: true, encoding: .utf8)
        try "keep me".write(to: second, atomically: true, encoding: .utf8)
        _ = try await SVNRemoteMutation.commit(SVNRemoteMutation.upload(sources: [first, second], directory: repository, existing: [], overwrite: false),
            directory: repository, revision: "0", message: "初始文件", client: client, executable: mucc)
        let items = try await list(repository, client: client)
        try "other user content".write(to: first, atomically: true, encoding: .utf8)
        _ = try await SVNRemoteMutation.commit(SVNRemoteMutation.upload(sources: [first], directory: repository, existing: items, overwrite: true),
            directory: repository, revision: "1", message: "其它客户端修改", client: client, executable: mucc)
        try "stale local content".write(to: first, atomically: true, encoding: .utf8)
        let stale = RemoteMutationPlan(actions: [.remove(repository.appendingPathComponent("second.txt")), .put(source: first, target: repository.appendingPathComponent("first.txt"))])
        do {
            _ = try await SVNRemoteMutation.commit(stale, directory: repository, revision: "1", message: "过期基准应失败", client: client, executable: mucc)
            XCTFail("不应覆盖其它客户端的修改")
        } catch {}
        let original = try await cat(repository.appendingPathComponent("first.txt"), client: client)
        let kept = try await cat(repository.appendingPathComponent("second.txt"), client: client)
        XCTAssertEqual(original, "other user content"); XCTAssertEqual(kept, "keep me")
    }

    func testValidationPreventsAmbiguousAndOutsideOperations() async throws {
        let directory = URL(string: "https://example.com/repo/project")!
        for name in ["", ".", "..", ".svn", "../other", "line\nbreak"] { XCTAssertThrowsError(try SVNRemoteMutation.child(name, in: directory)) }
        XCTAssertEqual(try SVNRemoteMutation.child("中文 @ # %.txt", in: directory).lastPathComponent, "中文 @ # %.txt")
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("svndesk-upload-validation-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let file = base.appendingPathComponent("sample.txt"), link = base.appendingPathComponent("link")
        try "content".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertThrowsError(try SVNRemoteMutation.upload(sources: [link], directory: directory, existing: [], overwrite: false))
        XCTAssertThrowsError(try SVNRemoteMutation.upload(sources: [file, file], directory: directory, existing: [], overwrite: false))
        let client = SVNClient()
        for target in [directory, URL(string: "https://example.com/repo/elsewhere")!, URL(string: "https://other.example.com/repo/project/file")!] {
            do {
                _ = try await SVNRemoteMutation.commit(.init(actions: [.remove(target)]), directory: directory, revision: "1", message: "拒绝越界", client: client, executable: "/does-not-run")
                XCTFail("越界操作应在启动进程前被拒绝")
            } catch { XCTAssertTrue(error.localizedDescription.contains("当前目录")) }
        }
        XCTAssertEqual(SVNRepository.displayDate("invalid"), "—")
    }
}
