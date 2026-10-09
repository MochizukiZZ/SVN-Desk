import Foundation

public enum SVNDownload {
    public static func save(_ source: URL, to destination: URL, revision: String, overwrite: Bool,
                            client: SVNClient, executable: String? = nil, credentials: SVNCredentials = .init()) async throws {
        let version = try SVNRepository.revision(revision)
        guard version != "HEAD" else { throw SVNFailure("下载需要固定的仓库版本。") }
        let manager = FileManager.default
        let parent = destination.deletingLastPathComponent()
        let temporary = parent.appendingPathComponent(".svndesk-download-" + UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: temporary, withIntermediateDirectories: false,
                                    attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: temporary) }
        let staged = temporary.appendingPathComponent("content")
        // export 直接写入磁盘，支持大文件和二进制文件，不生成 .svn。
        _ = try await client.run(["export", "--ignore-externals", "-r", version, "--",
                                  SVNRepository.target(source, revision: version), staged.path],
                                 executable: executable, credentials: credentials,
                                 cancellationMessage: "下载已取消，已保存的文件保留。")
        guard let stagedAttributes = try? manager.attributesOfItem(atPath: staged.path),
              stagedAttributes[.type] as? FileAttributeType == .typeRegular else {
            throw SVNFailure("请选择普通文件下载。")
        }
        if let existing = try? manager.attributesOfItem(atPath: destination.path) {
            guard overwrite, existing[.type] as? FileAttributeType == .typeRegular else {
                throw SVNFailure("目标已存在或不是普通文件：\(destination.lastPathComponent)")
            }
            _ = try manager.replaceItemAt(destination, withItemAt: staged)
        } else {
            try manager.moveItem(at: staged, to: destination)
        }
    }

    public static func destination(for name: String, in directory: URL, keepBoth: Bool) throws -> URL {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else {
            throw SVNFailure("文件名无效。")
        }
        let target = directory.appendingPathComponent(name)
        guard keepBoth else { return target }
        let manager = FileManager.default
        func exists(_ url: URL) -> Bool { (try? manager.attributesOfItem(atPath: url.path)) != nil }
        if !exists(target) { return target }
        let ext = target.pathExtension, base = ext.isEmpty ? name : target.deletingPathExtension().lastPathComponent
        var index = 1
        while true {
            let candidate = directory.appendingPathComponent(base + " (\(index))" + (ext.isEmpty ? "" : "." + ext))
            if !exists(candidate) { return candidate }
            index += 1
        }
    }
}
