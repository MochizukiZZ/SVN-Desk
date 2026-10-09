import AppKit
import FinderSync
import OSLog

@objc(SVNDeskFinderSync) final class FinderSync: FIFinderSync {
    private var snapshot = FinderSnapshot(roots: [])
    private var tracked = Set<URL>()
    private var observed = Set<URL>()
    private var applied: [URL: String] = [:]
    private var timer: Timer?
    private var lastRead: Date?
    private lazy var controller = FIFinderSyncController.default()
    private let logger = Logger(subsystem: "net.wologic.svndesk.finder", category: "badges")

    override init() {
        super.init()
        for badge in [SVNBadge.modified, .added, .unversioned, .conflict, .deleted] {
            controller.setBadgeImage(Self.image(badge), label: badge.title, forBadgeIdentifier: badge.rawValue)
        }
        logger.notice("Finder 扩展初始化，状态目录：\(FinderSnapshot.storeURL.path, privacy: .public)")
        reload()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.reload() }
        NSLog("SVN Desk Finder 扩展已加载，监控 %ld 个工作副本", snapshot.roots.count)
    }
    private func reload() {
        let modified = (try? FileManager.default.attributesOfItem(atPath: FinderSnapshot.storeURL.path)[.modificationDate]) as? Date
        if modified != lastRead || lastRead == nil {
            do {
                snapshot = try FinderSnapshot.read(); lastRead = modified
                let directories = Set(snapshot.roots.map { URL(fileURLWithPath: $0.path, isDirectory: true) })
                if controller.directoryURLs != directories { controller.directoryURLs = directories }
                logger.debug("快照更新：目录 \(self.snapshot.roots.count, privacy: .public)，角标 \(self.snapshot.roots.reduce(0) { $0 + $1.badges.count }, privacy: .public)")
            } catch {
                logger.error("读取快照失败：\(error.localizedDescription, privacy: .public)")
                snapshot = FinderSnapshot(roots: []); controller.directoryURLs = []
            }
        }
        for url in tracked { apply(url) }
    }
    private func apply(_ url: URL, force: Bool = false) {
        let identifier = snapshot.badge(for: url.path)?.rawValue ?? ""
        guard force || applied[url] != identifier else { return }
        applied[url] = identifier; controller.setBadgeIdentifier(identifier, for: url)
        logger.debug("设置角标：\(identifier, privacy: .public)")
    }
    override func beginObservingDirectory(at url: URL) { observed.insert(url); reload() }
    override func endObservingDirectory(at url: URL) {
        observed.remove(url)
        tracked = tracked.filter { file in observed.contains { FinderSnapshot.contains(file.path, in: $0.path) } }
        applied = applied.filter { tracked.contains($0.key) }
    }
    override func requestBadgeIdentifier(for url: URL) {
        guard !url.pathComponents.contains(".svn") else { return }
        tracked.insert(url); apply(url, force: true)
    }
    override var toolbarItemName: String { "SVN Desk" }
    override var toolbarItemToolTip: String { "打开 SVN 工作副本与仓库浏览器" }
    override var toolbarItemImage: NSImage { NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: "SVN Desk")! }
    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        let menu = NSMenu(title: "SVN Desk")
        func add(_ title: String, _ action: String) {
            let item = NSMenuItem(title: title, action: #selector(performAction(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = action; menu.addItem(item)
        }
        add("在 SVN Desk 中打开", "open")
        let urls = controller.selectedItemURLs() ?? controller.targetedURL().map { [$0] } ?? []
        if !urls.isEmpty {
            add("查看 SVN 差异", "diff")
            add("提交所选变更…", "commit")
            add("更新工作副本…", "update")
            add("查看提交历史", "log")
            add("刷新 SVN 标记", "refresh")
        }
        menu.addItem(.separator()); add("浏览 SVN 仓库", "browser")
        return menu
    }
    @objc private func performAction(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? String else { return }
        let urls = controller.selectedItemURLs() ?? controller.targetedURL().map { [$0] } ?? []
        if let url = FinderRequest(action: action, paths: urls.map(\.path)).url { NSWorkspace.shared.open(url) }
    }
    private static func image(_ badge: SVNBadge) -> NSImage {
        let color: NSColor
        let symbol: String
        switch badge {
        case .modified: color = .systemBlue; symbol = "M"
        case .added: color = .systemGreen; symbol = "+"
        case .unversioned: color = .systemGray; symbol = "?"
        case .conflict: color = .systemRed; symbol = "!"
        case .deleted: color = .systemOrange; symbol = "−"
        }
        let vector = NSImage(size: NSSize(width: 32, height: 32), flipped: false) { rect in
            color.setFill(); NSBezierPath(ovalIn: rect).fill()
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 23, weight: .bold), .foregroundColor: NSColor.white]
            let size = (symbol as NSString).size(withAttributes: attributes)
            (symbol as NSString).draw(at: NSPoint(x: (32 - size.width) / 2, y: (32 - size.height) / 2), withAttributes: attributes)
            return true
        }
        // 绘制回调不能直接跨 XPC 传递，先生成可序列化的位图表示。
        return vector.tiffRepresentation.flatMap(NSImage.init(data:)) ?? vector
    }
}
