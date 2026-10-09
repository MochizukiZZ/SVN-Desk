import Foundation

public struct SVNCredentials: Sendable {
    public var username: String
    public var password: String
    public init(username: String = "", password: String = "") { self.username = username; self.password = password }
}

public final class SVNClient: @unchecked Sendable {
    private let lock = NSLock()
    private var processes: [UUID: Process] = [:]
    public init() {}

    public static func executable(custom: String = "") -> String? {
        let candidates = [custom, "/opt/homebrew/bin/svn", "/usr/local/bin/svn", "/usr/bin/svn"]
        return candidates.first { !$0.isEmpty && FileManager.default.isExecutableFile(atPath: $0) }
    }
    // 末尾空 peg revision 防止 SVN 将文件名里的 @ 解释为版本号。
    public static func target(_ path: String) -> String { (path.hasPrefix("/") || path.hasPrefix("./") ? path : "./" + path) + "@" }
    public func cancelAll() {
        lock.lock(); let running = Array(processes.values); lock.unlock()
        for process in running where process.isRunning { process.interrupt() }
    }
    private func register(_ process: Process, id: UUID) { lock.lock(); processes[id] = process; lock.unlock() }
    private func unregister(_ id: UUID) { lock.lock(); processes.removeValue(forKey: id); lock.unlock() }

    public func run(_ arguments: [String], directory: String? = nil, executable: String? = nil, credentials: SVNCredentials = .init(), cancellationMessage: String = "操作已取消。请刷新工作副本状态。") async throws -> Data {
        guard let binary = executable ?? Self.executable() else { throw SVNFailure("未找到 SVN。请安装 Subversion，或在设置中指定 svn 的完整路径。") }
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let id = UUID(), process = Process()
                let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("svndesk-" + id.uuidString, isDirectory: true)
                do {
                    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
                    defer { try? FileManager.default.removeItem(at: temporary); self.unregister(id) }
                    let outputURL = temporary.appendingPathComponent("stdout"), errorURL = temporary.appendingPathComponent("stderr")
                    FileManager.default.createFile(atPath: outputURL.path, contents: nil)
                    FileManager.default.createFile(atPath: errorURL.path, contents: nil)
                    let output = try FileHandle(forWritingTo: outputURL), error = try FileHandle(forWritingTo: errorURL)
                    defer { try? output.close(); try? error.close() }
                    process.executableURL = URL(fileURLWithPath: binary)
                    var options = ["--non-interactive"]
                    if !credentials.username.isEmpty { options += ["--username", credentials.username] }
                    if !credentials.password.isEmpty { options += ["--password-from-stdin", "--no-auth-cache"] }
                    process.arguments = options + arguments
                    if let directory { process.currentDirectoryURL = URL(fileURLWithPath: directory) }
                    var environment = ProcessInfo.processInfo.environment
                    environment["LC_ALL"] = "en_US.UTF-8"; process.environment = environment
                    process.standardOutput = output; process.standardError = error
                    let input = Pipe(); process.standardInput = input
                    try process.run(); self.register(process, id: id)
                    if !credentials.password.isEmpty { try input.fileHandleForWriting.write(contentsOf: Data((credentials.password + "\n").utf8)) }
                    try input.fileHandleForWriting.close()
                    process.waitUntilExit()
                    let data = try Data(contentsOf: outputURL)
                    if process.terminationStatus != 0 {
                        let detail = String(decoding: try Data(contentsOf: errorURL), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                        throw SVNFailure(process.terminationReason == .uncaughtSignal ? cancellationMessage : (detail.isEmpty ? "SVN 操作失败（\(process.terminationStatus)）。" : detail))
                    }
                    continuation.resume(returning: data)
                } catch {
                    if process.isRunning { process.terminate(); process.waitUntilExit() }
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    public func status(at path: String, executable: String? = nil) async throws -> [SVNEntry] {
        try SVNParser.status(await run(["status", "--xml", "--", ".@"], directory: path, executable: executable))
    }
    public func info(at path: String, executable: String? = nil, credentials: SVNCredentials = .init()) async throws -> SVNInfo {
        try SVNParser.info(await run(["info", "--xml", "--", ".@"], directory: path, executable: executable, credentials: credentials))
    }
}
