import AppKit
import SwiftUI
import SVNCore

struct WorkingCopy: Identifiable, Codable, Hashable {
    var id: String { path }
    let path: String
    var name: String { URL(fileURLWithPath: path).lastPathComponent }
}
struct Activity: Identifiable {
    let id = UUID()
    let date = Date()
    let title: String
    let output: String
    let failed: Bool
}

@MainActor final class AppModel: ObservableObject {
    @Published var copies: [WorkingCopy] = []
    @Published var selectedCopy: String? { didSet { if oldValue != selectedCopy { resetAndLoad() } } }
    @Published var entries: [SVNEntry] = []
    @Published var info: SVNInfo?
    @Published var selectedFile: String?
    @Published var checked: Set<String> = []
    @Published var logs: [SVNLog] = []
    @Published var selectedLog: String?
    @Published var diff = ""
    @Published var historyDiff = ""
    @Published var busy = false
    @Published var busyTitle = ""
    @Published var errorMessage: String?
    @Published var activities: [Activity] = []
    @Published var search = ""
    @Published var filter = "全部"
    @Published var page = "变更"
    @Published var repositoryMode = false
    @Published var repositoryRefreshID = UUID()
    @Published var checkoutSeedURL = ""
    @Published var checkoutSeedRevision = "HEAD"
    @Published var showCheckout = false
    @Published var showCommit = false
    @Published var showSettings = false
    @Published var username = ""
    @Published var password = ""
    @Published private(set) var savedCredentials: [CredentialProfile] = []
    @Published private(set) var selectedCredentialID: String?
    @Published private(set) var credentialBusy = true
    @Published var credentialError: String?
    private let credentialStore = CredentialStore(vault: KeychainCredentialVault(service: (Bundle.main.bundleIdentifier ?? "net.wologic.svndesk") + ".credentials"))
    private var credentialStartupTask: Task<Void, Never>?
    @Published var binaryPath = UserDefaults.standard.string(forKey: "svnBinary") ?? "" {
        didSet { UserDefaults.standard.set(binaryPath, forKey: "svnBinary") }
    }
    let client = SVNClient()
    private let finderBridge = FinderBridge()
    var binary: String? { SVNClient.executable(custom: binaryPath) }
    var credentials: SVNCredentials { .init(username: username, password: password) }
    func authentication() throws -> SVNCredentials {
        guard !credentialBusy else { throw SVNFailure("正在读取已保存的凭据，请稍后重试。") }
        if let credentialError { throw SVNFailure(credentialError) }
        return credentials
    }
    var current: WorkingCopy? { copies.first { $0.path == selectedCopy } }
    var changes: [SVNEntry] { entries.filter(\.isChanged) }
    var visibleEntries: [SVNEntry] {
        changes.filter { entry in
            (search.isEmpty || entry.path.localizedCaseInsensitiveContains(search)) &&
            (filter == "全部" || (filter == "可提交" && entry.canCommit) || (filter == "未跟踪" && entry.status == "unversioned") || (filter == "冲突" && entry.isConflict))
        }
    }
    var commitEntries: [SVNEntry] { entries.filter { checked.contains($0.path) && $0.canCommit } }
    var selectedEntry: SVNEntry? { entries.first { $0.path == selectedFile } }

    func refreshCurrentView() async {
        if repositoryMode { repositoryRefreshID = UUID() }
        else { await refresh() }
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: "workingCopies"), let saved = try? JSONDecoder().decode([WorkingCopy].self, from: data) { copies = saved }
        selectedCopy = copies.first?.path
        credentialStartupTask = Task {
            defer { credentialBusy = false }
            do { applyCredentials(try await credentialStore.restore()) }
            catch {
                if let configuration = try? await credentialStore.configuration() {
                    savedCredentials = configuration.profiles; selectedCredentialID = configuration.selectedID
                    username = savedCredentials.first(where: { $0.id == selectedCredentialID })?.username ?? ""
                }
                password = ""
                credentialError = error.localizedDescription
            }
        }
        if FileManager.default.fileExists(atPath: Bundle.main.bundleURL.appendingPathComponent("Contents/PlugIns/SVNFinderSync.appex").path) {
            finderBridge.start(roots: { [weak self] in self?.copies.map(\.path) ?? [] }, binary: { [weak self] in self?.binary }, paused: { [weak self] in self?.busy ?? true })
        }
    }
    private func applyCredentials(_ selection: CredentialSelection) {
        savedCredentials = selection.configuration.profiles
        selectedCredentialID = selection.configuration.selectedID
        username = selection.credentials.username; password = selection.credentials.password
        credentialError = nil
    }
    func selectCredential(_ id: String?) async {
        guard !busy, !credentialBusy else { return }
        credentialBusy = true; defer { credentialBusy = false }
        do { applyCredentials(try await credentialStore.select(id)) }
        catch {
            // 保留可编辑的名称与用户名，让用户能补回丢失的钥匙串密码。
            selectedCredentialID = id
            username = savedCredentials.first(where: { $0.id == id })?.username ?? ""; password = ""
            credentialError = error.localizedDescription
        }
    }
    func saveCredential(id: String?, name: String, username: String, password: String) async throws {
        guard !busy, !credentialBusy else { throw SVNFailure("请等待当前操作完成后再保存凭据。") }
        credentialBusy = true; defer { credentialBusy = false }
        applyCredentials(try await credentialStore.save(id: id, name: name, username: username, password: password))
    }
    func deleteCredential(_ id: String) async throws {
        guard !busy, !credentialBusy else { throw SVNFailure("请等待当前操作完成后再删除凭据。") }
        credentialBusy = true; defer { credentialBusy = false }
        applyCredentials(try await credentialStore.delete(id))
    }
    func persist() {
        UserDefaults.standard.set(try? JSONEncoder().encode(copies), forKey: "workingCopies")
        Task { await finderBridge.refresh() }
    }
    func resetAndLoad() {
        entries = []; checked = []; info = nil; selectedFile = nil; logs = []; selectedLog = nil; diff = ""; historyDiff = ""; search = ""
        Task { await refresh() }
    }
    func run(_ title: String, action: @escaping () async throws -> String) async {
        await credentialStartupTask?.value
        guard !busy else { return }
        busy = true; busyTitle = title
        defer { busy = false; busyTitle = "" }
        do {
            _ = try authentication()
            let output = try await action()
            activities.insert(Activity(title: title, output: output.isEmpty ? "操作完成" : output, failed: false), at: 0)
        } catch {
            errorMessage = error.localizedDescription
            activities.insert(Activity(title: title, output: error.localizedDescription, failed: true), at: 0)
        }
        activities = Array(activities.prefix(100))
    }
    func loadStatus(_ path: String) async throws {
        let newInfo = try await client.info(at: path, executable: binary)
        let newEntries = try await client.status(at: path, executable: binary)
        guard selectedCopy == path else { return }
        info = newInfo; entries = newEntries.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        checked.formIntersection(Set(entries.filter(\.canCommit).map(\.path)))
        if !entries.contains(where: { $0.path == selectedFile }) { selectedFile = nil; diff = "" }
    }
    func refresh() async {
        guard let path = selectedCopy else { return }
        await run("刷新状态") {
            try await self.loadStatus(path)
            return "\(self.changes.count) 项变更 · \(self.entries.filter(\.isConflict).count) 项冲突"
        }
        if selectedFile != nil && page == "变更" { await loadDiff() }
    }
    func openFolder() {
        guard !busy else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.message = "选择已有的 SVN 工作副本目录"; panel.prompt = "添加工作副本"
        if panel.runModal() == .OK, let url = panel.url { Task { await addCopy(url.path) } }
    }
    func addCopy(_ path: String) async {
        await run("添加工作副本") {
            let result = try await self.client.info(at: path, executable: self.binary)
            let root = result.workingRoot.isEmpty ? path : result.workingRoot
            if !self.copies.contains(where: { $0.path == root }) { self.copies.append(WorkingCopy(path: root)); self.persist() }
            // 此处直接加载，避免选择变化触发的任务遇到 busy 而跳过。
            self.selectedCopy = root
            try await self.loadStatus(root)
            return root
        }
    }
    func removeCopy(_ copy: WorkingCopy) {
        copies.removeAll { $0.id == copy.id }; persist()
        if selectedCopy == copy.id { selectedCopy = copies.first?.id }
    }
    func mutate(_ title: String, arguments: [String]) async {
        guard let path = selectedCopy else { return }
        await run(title) {
            let data = try await self.client.run(arguments, directory: path, executable: self.binary, credentials: self.credentials)
            try await self.loadStatus(path)
            self.logs = []; self.selectedLog = nil; self.historyDiff = ""
            return String(decoding: data, as: UTF8.self)
        }
        // 即使命令部分成功后失败，也重新读取真实状态。
        if selectedCopy == path { try? await loadStatus(path) }
        if selectedFile != nil { await loadDiff() }
    }
    func update() async { await mutate("更新工作副本", arguments: ["update", "--", ".@"]); if page == "历史" { await loadLogs() } }
    func stage(_ entry: SVNEntry) async {
        if entry.status == "unversioned" { await mutate("加入版本控制", arguments: ["add", "--", SVNClient.target(entry.path)]) }
        else if entry.status == "missing" { await mutate("登记缺失文件的删除", arguments: ["delete", "--", SVNClient.target(entry.path)]) }
    }
    func revert(_ paths: [String]) async { await mutate("撤销本地修改", arguments: ["revert", "--depth", "infinity", "--"] + paths.map(SVNClient.target)) }
    func resolve(_ entry: SVNEntry) async { await mutate("标记冲突已解决", arguments: ["resolve", "--accept", "working", "--", SVNClient.target(entry.path)]) }
    func commit(_ message: String) async {
        let paths = commitEntries.map(\.path)
        guard !paths.isEmpty, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        showCommit = false
        await mutate("提交 \(paths.count) 项变更", arguments: ["commit", "--depth", "empty", "-m", message, "--"] + paths.map(SVNClient.target))
    }
    func loadDiff() async {
        guard let path = selectedCopy, let entry = selectedEntry, !busy else { return }
        let selected = entry.path
        diff = "正在读取差异…"
        await run("查看差异") {
            let value: String
            if entry.status == "unversioned" {
                let url = URL(fileURLWithPath: path).appendingPathComponent(selected)
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                if values.isRegularFile == true && (values.fileSize ?? 0) <= 1_000_000,
                   let text = String(data: try Data(contentsOf: url), encoding: .utf8), !text.contains("\0") {
                    value = "未跟踪文件预览\n\n" + text
                } else { value = "目录、二进制或超过 1 MB 的文件，请在 Finder 中查看。" }
            } else {
                let data = try await self.client.run(["diff", "--internal-diff", "--old", SVNClient.target(selected)], directory: path, executable: self.binary)
                value = data.isEmpty ? "没有文本差异。可能是目录、二进制文件或仅版本状态改变。" : String(decoding: data.prefix(1_000_000), as: UTF8.self)
            }
            if self.selectedCopy == path && self.selectedFile == selected { self.diff = value }
            return "已读取 \(selected)"
        }
        if selectedCopy == path && selectedFile == selected && diff == "正在读取差异…" { diff = "差异读取失败，请查看操作记录。" }
        if selectedCopy == path && selectedFile != nil && selectedFile != selected { await loadDiff() }
    }
    func loadLogs() async {
        guard let path = selectedCopy else { return }
        await run("读取提交历史") {
            let data = try await self.client.run(["log", "--xml", "-v", "--limit", "100", "-r", "HEAD:1", "--", ".@"], directory: path, executable: self.binary, credentials: self.credentials)
            if self.selectedCopy == path { self.logs = try SVNParser.logs(data) }
            return "已读取最近 \(self.logs.count) 次提交"
        }
    }
    func revisionDiff(_ revision: String) async {
        guard let path = selectedCopy, !busy else { return }
        historyDiff = "正在读取版本差异…"
        await run("查看 r\(revision) 差异") {
            let data = try await self.client.run(["diff", "--internal-diff", "-c", revision, "--", ".@"], directory: path, executable: self.binary, credentials: self.credentials)
            if self.selectedCopy == path && self.selectedLog == revision { self.historyDiff = data.isEmpty ? "此版本在当前目录下没有文本差异。" : String(decoding: data.prefix(1_000_000), as: UTF8.self) }
            return "已读取 r\(revision)"
        }
        if historyDiff == "正在读取版本差异…" { historyDiff = "版本差异读取失败，请查看操作记录。" }
    }
    func presentCheckout(url: String = "", revision: String = "HEAD") {
        checkoutSeedURL = url; checkoutSeedRevision = revision; showCheckout = true
    }
    func checkout(url: String, destination: String, revision: String = "HEAD") async {
        guard let parsed = URL(string: url), ["https", "http", "svn", "svn+ssh", "file"].contains(parsed.scheme ?? ""), parsed.user == nil, parsed.password == nil else {
            errorMessage = "请输入合法的仓库 URL，账号密码请填写在设置中。"; return
        }
        await run("检出仓库") {
            let version = try SVNRepository.revision(revision)
            let data = try await self.client.run(["checkout", "-r", version, "--", url + "@" + version, destination], executable: self.binary, credentials: self.credentials)
            let copy = WorkingCopy(path: destination)
            if !self.copies.contains(copy) { self.copies.append(copy); self.persist() }
            self.repositoryMode = false
            self.selectedCopy = destination
            try await self.loadStatus(destination)
            self.showCheckout = false
            return String(decoding: data, as: UTF8.self)
        }
    }
    func handleFinderURL(_ url: URL) async {
        guard let request = FinderRequest.parse(url) else { return }
        NSApp.activate(ignoringOtherApps: true)
        if request.action == "browser" { repositoryMode = true; return }
        // 冷启动时先等待只读状态刷新；写入操作仍要求用户完成后再重试。
        let deadline = Date().addingTimeInterval(5)
        while busy && busyTitle == "刷新状态" && Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        guard !busy else { errorMessage = "当前 SVN 操作尚未结束，请完成后再使用 Finder 操作。"; return }
        guard let path = request.paths.first,
              let copy = copies.filter({ FinderSnapshot.contains(path, in: $0.path) }).max(by: { $0.path.count < $1.path.count }),
              request.paths.allSatisfy({ FinderSnapshot.contains($0, in: copy.path) }) else {
            if request.action != "open" { errorMessage = "请先将该目录添加到 SVN Desk 的工作副本列表。" }
            return
        }
        repositoryMode = false
        selectedCopy = copy.path
        await refresh()
        let relative = request.paths.map { $0 == copy.path ? "." : String($0.dropFirst(copy.path.count + 1)) }
        switch request.action {
        case "diff":
            page = "变更"; selectedFile = relative.first
            await loadDiff()
        case "commit":
            page = "变更"
            checked = Set(entries.filter { entry in entry.canCommit && relative.contains(where: { $0 == "." || entry.path == $0 || entry.path.hasPrefix($0 + "/") }) }.map(\.path))
            if checked.isEmpty { errorMessage = "所选路径没有可提交的变更。未跟踪文件需要先加入版本控制。" }
            else { showCommit = true }
        case "update":
            let alert = NSAlert(); alert.messageText = "更新工作副本？"; alert.informativeText = copy.path
            alert.addButton(withTitle: "更新"); alert.addButton(withTitle: "取消")
            if alert.runModal() == .alertFirstButtonReturn { await update() }
        case "log": page = "历史"; await loadLogs()
        default: page = "变更"
        }
        await finderBridge.refresh()
    }
    func revealCopy(_ copy: WorkingCopy) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: copy.path)])
    }
    func reveal(_ path: String? = nil) {
        guard let current else { return }
        let url = path.map { URL(fileURLWithPath: current.path).appendingPathComponent($0) } ?? URL(fileURLWithPath: current.path)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
    func openFile(_ entry: SVNEntry) {
        guard let current else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: current.path).appendingPathComponent(entry.path))
    }
    func chooseAll() { checked = Set(visibleEntries.filter(\.canCommit).map(\.path)) }
}
