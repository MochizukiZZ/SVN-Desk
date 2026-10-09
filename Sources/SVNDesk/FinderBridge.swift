import AppKit
import FinderSync
import SVNCore

@MainActor final class FinderBridge {
    private let client = SVNClient()
    private var timer: Timer?
    private var scanning = false
    private var roots: () -> [String] = { [] }
    private var binary: () -> String? = { nil }
    private var paused: () -> Bool = { false }
    func start(roots: @escaping () -> [String], binary: @escaping () -> String?, paused: @escaping () -> Bool) {
        self.roots = roots; self.binary = binary; self.paused = paused
        // 立即发布配置，让新启动的 Finder 扩展先得到监控目录。
        try? FinderSnapshot(roots: roots().map { FinderRootState(path: $0, entries: nil) }).write()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in Task { await self?.refresh() } }
        Task { await refresh() }
    }
    func refresh() async {
        guard !scanning, !paused() else { return }
        scanning = true; defer { scanning = false }
        let paths = roots(), executable = binary()
        var states: [FinderRootState] = []
        for path in paths {
            guard let executable else { states.append(.init(path: path, entries: nil)); continue }
            do { states.append(.init(path: path, entries: try await client.status(at: path, executable: executable))) }
            catch { states.append(.init(path: path, entries: nil)) }
        }
        guard paths == roots() else { return }
        do { try FinderSnapshot(roots: states).write() }
        catch { NSLog("SVN Desk：Finder 状态快照写入失败：%@", error.localizedDescription) }
    }
    static func showManagement() { FIFinderSyncController.showExtensionManagementInterface() }
}
