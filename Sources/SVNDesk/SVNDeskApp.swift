import AppKit
import SwiftUI

@main struct SVNDeskApp: App {
    @StateObject private var model = AppModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene {
        WindowGroup("SVN Desk") {
            ContentView().environmentObject(model).frame(minWidth: 1180, minHeight: 650)
                .onAppear { delegate.model = model }
                .task { await model.refresh() }
        }
        .defaultSize(width: 1360, height: 840)
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("添加工作副本…") { model.openFolder() }.keyboardShortcut("o").disabled(model.busy)
                Button("检出仓库…") { model.presentCheckout() }.keyboardShortcut("n").disabled(model.busy)
            }
            CommandMenu("SVN") {
                Button("仓库浏览器") { model.repositoryMode = true }.keyboardShortcut("b").disabled(model.busy)
                Button("刷新") { Task { await model.refreshCurrentView() } }.keyboardShortcut("r").disabled(model.busy || (!model.repositoryMode && model.current == nil))
                Button("更新工作副本") { Task { await model.update() } }.keyboardShortcut("u", modifiers: [.command, .shift]).disabled(model.busy || model.current == nil)
                Button("提交变更…") { model.showCommit = true }.keyboardShortcut("k").disabled(model.busy || model.commitEntries.isEmpty)
            }
            CommandGroup(replacing: .appSettings) {
                Button("设置…") { model.showSettings = true }.keyboardShortcut(",").disabled(model.busy)
            }
        }
    }
}
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel? {
        didSet {
            guard let model else { return }
            let urls = pendingURLs; pendingURLs.removeAll()
            for url in urls { Task { await model.handleFinderURL(url) } }
        }
    }
    private var pendingURLs: [URL] = []
    func application(_ application: NSApplication, open urls: [URL]) {
        application.activate(ignoringOtherApps: true)
        application.windows.first(where: { $0.title == "SVN Desk" })?.makeKeyAndOrderFront(nil)
        guard let model else { pendingURLs.append(contentsOf: urls); return }
        for url in urls { Task { await model.handleFinderURL(url) } }
    }
    @MainActor func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.busy else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "SVN 操作正在进行"
        alert.informativeText = "当前操作：\(model.busyTitle)。取消后，请刷新仓库或工作副本，确认实际提交结果。"
        alert.addButton(withTitle: "返回应用")
        alert.addButton(withTitle: "取消操作并退出")
        if alert.runModal() == .alertSecondButtonReturn { model.client.cancelAll(); return .terminateNow }
        return .terminateCancel
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
