import Foundation

public enum RemoteAction: Sendable {
    case mkdir(URL)
    case put(source: URL, target: URL)
    case move(source: URL, target: URL)
    case remove(URL)
    public var targets: [URL] {
        switch self {
        case .mkdir(let url), .remove(let url): return [url]
        case .put(_, let target): return [target]
        case .move(let source, let target): return [source, target]
        }
    }
    var arguments: [String] {
        // svnmucc 把 URL 中的 @ 当作普通路径字符，不能追加 peg revision。
        switch self {
        case .mkdir(let url): return ["mkdir", url.absoluteString]
        case .put(let source, let target): return ["put", source.path, target.absoluteString]
        case .move(let source, let target): return ["mv", source.absoluteString, target.absoluteString]
        case .remove(let url): return ["rm", url.absoluteString]
        }
    }
}

public struct RemoteMutationPlan: Sendable {
    public let actions: [RemoteAction]
    public init(actions: [RemoteAction]) { self.actions = actions }
    public var fileCount: Int { actions.filter { if case .put = $0 { return true }; return false }.count }
    public var directoryCount: Int { actions.filter { if case .mkdir = $0 { return true }; return false }.count }
}

public enum SVNRemoteMutation {
    public static func executable(svn: String?) -> String? {
        let sibling = svn.map { URL(fileURLWithPath: $0).deletingLastPathComponent().appendingPathComponent("svnmucc").path } ?? ""
        return [sibling, "/opt/homebrew/bin/svnmucc", "/usr/local/bin/svnmucc", "/usr/bin/svnmucc"].first {
            !$0.isEmpty && FileManager.default.isExecutableFile(atPath: $0)
        }
    }
    public static func child(_ name: String, in directory: URL) throws -> URL {
        guard !name.isEmpty, name != ".", name != "..", name != ".svn", !name.contains("/"),
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw SVNFailure("名称不能为空，不能包含路径分隔符、控制字符，也不能使用 .、.. 或 .svn。")
        }
        return directory.appendingPathComponent(name)
    }
    public static func createDirectory(name: String, directory: URL, existing: [SVNRepositoryItem]) throws -> RemoteMutationPlan {
        let target = try child(name, in: directory)
        guard !existing.contains(where: { $0.name == name }) else { throw SVNFailure("仓库中已存在这个名称，请使用其它名称。") }
        return .init(actions: [.mkdir(target)])
    }
    public static func rename(item: SVNRepositoryItem, name: String, directory: URL, existing: [SVNRepositoryItem]) throws -> RemoteMutationPlan {
        let target = try child(name, in: directory)
        guard name != item.name else { throw SVNFailure("新名称与原名称相同。") }
        guard !existing.contains(where: { $0.name == name }) else { throw SVNFailure("仓库中已存在这个名称，不能覆盖重命名。") }
        return .init(actions: [.move(source: try child(item.name, in: directory), target: target)])
    }
    public static func delete(item: SVNRepositoryItem, directory: URL) throws -> RemoteMutationPlan {
        .init(actions: [.remove(try child(item.name, in: directory))])
    }
    public static func upload(sources: [URL], directory: URL, existing: [SVNRepositoryItem], overwrite: Bool) throws -> RemoteMutationPlan {
        guard !sources.isEmpty else { throw SVNFailure("请选择要上传的文件或目录。") }
        let names = sources.map(\.lastPathComponent)
        guard Set(names).count == names.count else { throw SVNFailure("所选项目包含同名文件或目录，不能上传到同一个仓库目录。") }
        var actions: [RemoteAction] = []
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        func append(_ source: URL, target: URL, exists: SVNRepositoryItem? = nil) throws {
            guard source.isFileURL, !source.path.contains("\n"), !source.path.contains("\r") else { throw SVNFailure("上传路径无效或包含换行。") }
            let attributes = try source.resourceValues(forKeys: keys)
            if attributes.isSymbolicLink == true { throw SVNFailure("暂不支持直接上传符号链接：\(source.lastPathComponent)") }
            if attributes.isDirectory == true {
                guard exists == nil else { throw SVNFailure("同名目录已存在，暂不支持合并目录：\(source.lastPathComponent)") }
                actions.append(.mkdir(target))
                let children = try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: Array(keys))
                    .filter { ![".svn", ".DS_Store"].contains($0.lastPathComponent) }
                    .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                for child in children { try append(child, target: Self.child(child.lastPathComponent, in: target)) }
            } else if attributes.isRegularFile == true {
                if let exists {
                    guard !exists.isDirectory else { throw SVNFailure("目标是目录，不能用文件覆盖：\(source.lastPathComponent)") }
                    guard overwrite else { throw SVNFailure("仓库中存在同名文件，请勾选“覆盖同名文件”或更换文件名。") }
                }
                guard FileManager.default.isReadableFile(atPath: source.path) else { throw SVNFailure("无法读取上传文件：\(source.lastPathComponent)") }
                actions.append(.put(source: source, target: target))
            } else { throw SVNFailure("请选择普通文件或目录：\(source.lastPathComponent)") }
        }
        for source in sources {
            try append(source, target: child(source.lastPathComponent, in: directory), exists: existing.first { $0.name == source.lastPathComponent })
        }
        return .init(actions: actions)
    }
    public static func commit(_ plan: RemoteMutationPlan, directory: URL, revision: String, message: String,
                              client: SVNClient, executable: String?, credentials: SVNCredentials = .init()) async throws -> String {
        guard let executable else { throw SVNFailure("未找到 svnmucc。请安装 Homebrew 的 subversion，或将 svnmucc 放在配置的 svn 同一目录。") }
        let base = try SVNRepository.revision(revision)
        guard base != "HEAD" else { throw SVNFailure("请先浏览仓库以取得提交基准版本。") }
        let message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, !message.contains("\0") else { throw SVNFailure("请填写有效的提交说明。") }
        guard !plan.actions.isEmpty else { throw SVNFailure("没有可提交的仓库操作。") }
        let directory = try SVNRepository.validate(directory.absoluteString)
        for action in plan.actions {
            for target in action.targets {
                _ = try SVNRepository.validate(target.absoluteString)
                guard SVNRepository.contains(target, in: directory), target.path != directory.path,
                      !target.pathComponents.contains(".."), !target.pathComponents.contains(".svn") else {
                    throw SVNFailure("仓库操作只能修改当前目录内的项目，不能修改仓库根目录或上级路径。")
                }
            }
        }
        let arguments = plan.actions.flatMap(\.arguments)
        guard !arguments.contains(where: { $0.contains("\n") || $0.contains("\r") || $0.contains("\0") }) else { throw SVNFailure("操作路径包含不支持的控制字符。") }
        // 大批量上传使用参数文件，避免超过系统 argv 长度；文件里不包含密码。
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("svndesk-remote-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: temporary) }
        let file = temporary.appendingPathComponent("actions.txt")
        try (arguments.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let result = try await client.run(["-r", base, "-m", message, "-X", file.path], executable: executable, credentials: credentials,
            cancellationMessage: "操作已取消，提交结果待确认。请刷新仓库检查是否已经生成版本，确认后再重试。")
        return String(decoding: result, as: UTF8.self)
    }
}
