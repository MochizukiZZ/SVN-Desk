import AppKit
import SwiftUI
import SVNCore

@MainActor final class RepositoryBrowserModel: ObservableObject {
    @Published var address = ""
    @Published var revision = "HEAD"
    @Published var loadedRevision = "HEAD"
    @Published var currentURL: URL?
    @Published var rootURL: URL?
    @Published var items: [SVNRepositoryItem] = []
    @Published var selected: String?
    @Published var preview = ""
    @Published var previewVisible = false
    @Published var creationDates: [String: String] = [:]
    @Published var creationErrors: [String: String] = [:]
    @Published var busy = false
    @Published var error: String?
    @Published var loadedFromHEAD = false
    @Published var mutation: RepositoryMutationDraft?
    @Published var lastResult: String?
    @Published var recent = UserDefaults.standard.stringArray(forKey: "recentRepositories") ?? []
    private var backStack: [URL] = []
    private let client = SVNClient()
    private let metadataClient = SVNClient()
    private var datesTask: Task<Void, Never>?
    private var datesGeneration = UUID()
    private var creationCache: [String: String] = [:]
    var canBack: Bool { !backStack.isEmpty }
    var canUp: Bool { if let currentURL, let rootURL { return currentURL.path != rootURL.path }; return false }
    var selectedItem: SVNRepositoryItem? { items.first { $0.id == selected } }
    var canModify: Bool { currentURL != nil && loadedFromHEAD && !busy }

    func browse(_ value: String, model: AppModel, remember: Bool = true) async {
        guard !busy else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            let url = try SVNRepository.validate(value), version = try SVNRepository.revision(revision)
            let credentials = try model.authentication()
            let target = SVNRepository.target(url, revision: version)
            let metadata = try SVNParser.info(await client.run(["info", "--xml", "-r", version, "--", target], executable: model.binary, credentials: credentials))
            guard metadata.kind == "dir" else { throw SVNFailure("请输入仓库目录的 URL；文件可在目录列表中选中预览。") }
            let resolvedRevision = metadata.revision
            let data = try await client.run(["list", "--xml", "-r", resolvedRevision, "--", SVNRepository.target(url, revision: resolvedRevision)], executable: model.binary, credentials: credentials)
            let result = try SVNRepository.parse(data)
            if remember, let previous = currentURL, previous != url { backStack.append(previous) }
            currentURL = url; loadedRevision = resolvedRevision; loadedFromHEAD = version == "HEAD"; rootURL = URL(string: metadata.root); address = url.absoluteString; items = result; selected = nil; preview = ""; previewVisible = false
            loadCreationDates(result, directory: url, revision: resolvedRevision, executable: model.binary, credentials: credentials)
            recent.removeAll { $0 == url.absoluteString }; recent.insert(url.absoluteString, at: 0); recent = Array(recent.prefix(12))
            UserDefaults.standard.set(recent, forKey: "recentRepositories")
        } catch { self.error = error.localizedDescription }
    }
    func enter(_ item: SVNRepositoryItem, model: AppModel) async {
        guard let currentURL else { return }
        if item.isDirectory { await browse(currentURL.appendingPathComponent(item.name).absoluteString, model: model) }
        else { selected = item.id; await readFile(model: model) }
    }
    func back(model: AppModel) async {
        guard !busy, let previous = backStack.last else { return }
        await browse(previous.absoluteString, model: model, remember: false)
        if currentURL == previous { _ = backStack.popLast() }
    }
    func up(model: AppModel) async {
        guard canUp, let currentURL else { return }
        await browse(currentURL.deletingLastPathComponent().absoluteString, model: model)
    }
    func readFile(model: AppModel) async {
        guard !busy else { return }
        guard let item = selectedItem, let currentURL else { previewVisible = false; preview = ""; return }
        if item.isDirectory { previewVisible = false; return }
        previewVisible = true
        if item.size > 1_000_000 { preview = "此文件超过 1 MB，请检出后查看。"; return }
        busy = true; preview = "正在读取文件…"
        defer { busy = false }
        do {
            let version = loadedRevision
            let url = currentURL.appendingPathComponent(item.name)
            let data = try await client.run(["cat", "-r", version, "--", SVNRepository.target(url, revision: version)], executable: model.binary, credentials: try model.authentication())
            if selected == item.id {
                preview = String(data: data, encoding: .utf8).flatMap { $0.contains("\0") ? nil : $0 } ?? "二进制文件，请检出后查看。"
            }
        } catch { preview = "读取失败：\(error.localizedDescription)" }
        if selected != item.id && selected != nil { busy = false; await readFile(model: model) }
    }
    func checkout(model: AppModel, selectedDirectory: Bool) {
        guard let currentURL else { return }
        let url = selectedDirectory && selectedItem?.isDirectory == true ? currentURL.appendingPathComponent(selectedItem!.name) : currentURL
        model.presentCheckout(url: url.absoluteString, revision: loadedRevision)
    }
    func cancel() { client.cancelAll(); datesTask?.cancel(); metadataClient.cancelAll() }
    func closePreview() { previewVisible = false; selected = nil; preview = "" }
    private func loadCreationDates(_ entries: [SVNRepositoryItem], directory: URL, revision: String, executable: String?, credentials: SVNCredentials) {
        datesTask?.cancel(); metadataClient.cancelAll()
        let generation = UUID(); datesGeneration = generation
        creationDates = [:]; creationErrors = [:]
        // 路径未变且最近修改版本未变时，可复用创建时间，不随仓库其它提交重复查询。
        func key(_ item: SVNRepositoryItem) -> String { directory.appendingPathComponent(item.name).absoluteString + "@" + item.revision }
        for item in entries { creationDates[item.id] = creationCache[key(item)] }
        let pending = entries.filter { creationDates[$0.id] == nil }, client = metadataClient
        let cacheKeys = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, key($0)) })
        if creationCache.count > 2000 { creationCache.removeAll() }
        datesTask = Task { [weak self] in
            guard let self else { return }
            await withTaskGroup(of: (String, String?, String?).self) { group in
                var iterator = pending.makeIterator()
                func add(_ item: SVNRepositoryItem) {
                    group.addTask {
                        guard !Task.isCancelled else { return (item.id, nil, nil) }
                        do {
                            let record = try await SVNRepository.creationRecord(for: directory.appendingPathComponent(item.name), revision: revision, client: client, executable: executable, credentials: credentials)
                            return (item.id, record?.date, record == nil ? "仓库未返回首次加入的记录。" : nil)
                        } catch { return (item.id, nil, error.localizedDescription) }
                    }
                }
                for _ in 0..<4 { if let item = iterator.next() { add(item) } }
                for await (name, date, error) in group {
                    guard !Task.isCancelled, self.datesGeneration == generation else { group.cancelAll(); return }
                    self.creationDates[name] = date ?? ""
                    self.creationErrors[name] = error
                    if let date, let key = cacheKeys[name] { self.creationCache[key] = date }
                    if let item = iterator.next() { add(item) }
                }
            }
        }
    }
    deinit { datesTask?.cancel(); metadataClient.cancelAll(); client.cancelAll() }
    func presentMutation(_ kind: RepositoryMutationKind, item: SVNRepositoryItem? = nil) {
        guard canModify, let currentURL else { return }
        var draft = RepositoryMutationDraft(kind: kind, directory: currentURL, revision: loadedRevision, existing: items, item: item)
        if kind == .upload {
            let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
            panel.message = "上传到当前仓库目录，无需检出"; panel.prompt = "选择上传内容"
            guard panel.runModal() == .OK else { return }
            draft.sources = panel.urls
        }
        mutation = draft
    }
    func commit(_ plan: RemoteMutationPlan, draft: RepositoryMutationDraft, message: String, model: AppModel) async -> Bool {
        guard canModify, !model.busy, currentURL == draft.directory, loadedRevision == draft.revision else {
            error = "仓库浏览位置或版本已变化，请关闭窗口并刷新仓库后重试。"; return false
        }
        busy = true; error = nil; lastResult = nil
        model.busy = true; model.busyTitle = draft.kind.rawValue
        do {
            let output = try await SVNRemoteMutation.commit(plan, directory: draft.directory, revision: draft.revision, message: message,
                client: model.client, executable: SVNRemoteMutation.executable(svn: model.binary), credentials: try model.authentication())
            model.activities.insert(Activity(title: draft.kind.rawValue, output: output, failed: false), at: 0)
            model.activities = Array(model.activities.prefix(100))
            busy = false; model.busy = false; model.busyTitle = ""
            revision = "HEAD"
            await browse(draft.directory.absoluteString, model: model, remember: false)
            lastResult = "\(draft.kind.rawValue)已提交：\(output.trimmingCharacters(in: .whitespacesAndNewlines))"
            if let refreshError = error { error = "提交已完成，但刷新失败：\(refreshError)。请点击浏览重新确认仓库状态。" }
            return true
        } catch {
            self.error = error.localizedDescription
            model.activities.insert(Activity(title: draft.kind.rawValue, output: error.localizedDescription, failed: true), at: 0)
            model.activities = Array(model.activities.prefix(100))
            busy = false; model.busy = false; model.busyTitle = ""
            return false
        }
    }
}

struct RepositoryBrowserView: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var browser = RepositoryBrowserModel()
    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    TextField("仓库 URL", text: $browser.address).textFieldStyle(.roundedBorder)
                        .onSubmit { Task { await browser.browse(browser.address, model: model) } }
                        .frame(minWidth: 220, maxWidth: .infinity).layoutPriority(-1)
                    HStack(spacing: 8) {
                        Menu {
                            ForEach(browser.recent, id: \.self) { url in
                                Button(url) { Task { await browser.browse(url, model: model) } }
                            }
                        } label: { Image(systemName: "clock.arrow.circlepath") }
                            .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 26)
                            .help("最近仓库").disabled(browser.busy)
                        Text("版本").foregroundStyle(.secondary)
                        TextField("HEAD", text: $browser.revision).textFieldStyle(.roundedBorder).frame(width: 70)
                        Button("浏览") { Task { await browser.browse(browser.address, model: model) } }
                            .disabled(browser.busy || browser.address.isEmpty || model.credentialBusy)
                    }.fixedSize()
                }.frame(height: 28)
                HStack(spacing: 8) {
                    Button { Task { await browser.back(model: model) } } label: { Image(systemName: "chevron.left").frame(width: 14) }
                        .help("返回").accessibilityLabel("返回").disabled(!browser.canBack || browser.busy)
                    Button { Task { await browser.up(model: model) } } label: { Image(systemName: "arrow.up").frame(width: 14) }
                        .help("上级目录").accessibilityLabel("上级目录").disabled(!browser.canUp || browser.busy)
                    Divider().frame(height: 18)
                    HStack(spacing: 8) {
                        Button("上传…") { browser.presentMutation(.upload) }
                        Button("新建目录…") { browser.presentMutation(.mkdir) }
                        Button("重命名…") { browser.presentMutation(.rename, item: browser.selectedItem) }.disabled(browser.selectedItem == nil)
                        Button("删除…", role: .destructive) { browser.presentMutation(.delete, item: browser.selectedItem) }.disabled(browser.selectedItem == nil)
                    }.disabled(!browser.canModify || model.busy || model.credentialBusy)
                    Spacer(minLength: 8)
                    SavedCredentialPicker(showsLabel: false, showsError: false).labelsHidden().frame(width: 220).disabled(browser.busy)
                    Button(browser.selectedItem?.isDirectory == true ? "检出所选目录…" : "检出当前目录…") {
                        browser.checkout(model: model, selectedDirectory: browser.selectedItem?.isDirectory == true)
                    }.disabled(browser.currentURL == nil || browser.busy || model.busy)
                }.fixedSize(horizontal: false, vertical: true).frame(height: 28)
            }.font(.system(size: 12)).controlSize(.regular).buttonStyle(.bordered).padding(12)
            if let error = model.credentialError {
                Text(error).font(.caption).foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.bottom, 8)
            }
            if let result = browser.lastResult {
                HStack {
                    Label("已提交", systemImage: "checkmark.circle").foregroundStyle(.green).help(result)
                    Spacer()
                    Button { browser.lastResult = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help("关闭提示")
                }.font(.caption).padding(.horizontal, 12).padding(.bottom, 8)
            }
            if let error = browser.error {
                HStack(alignment: .top) { Image(systemName: "exclamationmark.triangle"); Text(error).textSelection(.enabled); Spacer() }.font(.caption).foregroundStyle(.orange).padding(14).background(Color.orange.opacity(0.06))
            }
            Divider()
            if browser.currentURL == nil {
                Text("输入仓库 URL").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                if browser.previewVisible {
                    HSplitView { repositoryListing; previewPane }
                } else {
                    repositoryListing.frame(maxWidth: .infinity)
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: browser.selected) { _ in Task { await browser.readFile(model: model) } }
            .sheet(item: $browser.mutation) { draft in RepositoryMutationSheet(browser: browser, draft: draft).environmentObject(model) }
            .onAppear { if browser.address.isEmpty { browser.address = model.info?.url ?? browser.recent.first ?? "" } }
    }
    private var repositoryListing: some View {
        VStack(spacing: 0) {
            Table(browser.items, selection: $browser.selected) {
                TableColumn("名称") { item in
                    HStack(spacing: 8) {
                        Image(systemName: item.isDirectory ? "folder.fill" : "doc.text").foregroundStyle(item.isDirectory ? Color.accentColor : .secondary)
                        Text(item.name).lineLimit(1).truncationMode(.middle)
                    }.contentShape(Rectangle())
                        .contextMenu {
                            if item.isDirectory {
                                Button("打开目录") { Task { await browser.enter(item, model: model) } }
                                Button("检出这个目录…") { browser.selected = item.id; browser.checkout(model: model, selectedDirectory: true) }
                            }
                            Divider()
                            Button("重命名…") { browser.presentMutation(.rename, item: item) }.disabled(!browser.canModify || model.busy)
                            Button("删除…", role: .destructive) { browser.presentMutation(.delete, item: item) }.disabled(!browser.canModify || model.busy)
                            Button("复制仓库 URL") {
                                if let url = browser.currentURL?.appendingPathComponent(item.name) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.absoluteString, forType: .string) }
                            }
                        }
                }.width(min: 150, ideal: 230)
                TableColumn("版本") { Text("r\($0.revision)").font(.system(size: 11, design: .monospaced)) }.width(65)
                TableColumn("作者") { Text($0.author).font(.caption).lineLimit(1) }.width(85)
                TableColumn("创建时间") { item in
                    Text(browser.creationDates[item.id].map { $0.isEmpty ? "不可用" : SVNRepository.displayDate($0) } ?? "读取中…")
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                        .help(browser.creationErrors[item.id] ?? "该路径首次加入 SVN 的提交时间；复制或重命名按新路径计算。")
                }.width(138)
                TableColumn("修改时间") { item in
                    Text(SVNRepository.displayDate(item.date)).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                        .help("SVN 最近提交时间；不是本地文件系统的修改时间。")
                }.width(138)
                TableColumn("大小") { Text($0.isDirectory ? "—" : ByteCountFormatter.string(fromByteCount: Int64($0.size), countStyle: .file)).font(.caption).foregroundStyle(.secondary) }.width(75)
            }.contextMenu(forSelectionType: String.self) { selection in
                if let id = selection.first, let item = browser.items.first(where: { $0.id == id }) {
                    Button(item.isDirectory ? "打开目录" : "预览文件") { Task { await browser.enter(item, model: model) } }
                    if item.isDirectory { Button("检出这个目录…") { browser.selected = id; browser.checkout(model: model, selectedDirectory: true) } }
                    Divider()
                    Button("重命名…") { browser.presentMutation(.rename, item: item) }.disabled(!browser.canModify || model.busy)
                    Button("删除…", role: .destructive) { browser.presentMutation(.delete, item: item) }.disabled(!browser.canModify || model.busy)
                }
            } primaryAction: { selection in
                if let id = selection.first, let item = browser.items.first(where: { $0.id == id }) { Task { await browser.enter(item, model: model) } }
            }.disabled(browser.busy)
            Divider()
            HStack(spacing: 8) {
                Text(browser.currentURL?.path ?? "").lineLimit(1).truncationMode(.middle).help(browser.currentURL?.absoluteString ?? "")
                Spacer(minLength: 8)
                if browser.busy { ProgressView().controlSize(.small); Button("取消") { browser.cancel() } }
                if !browser.loadedFromHEAD { Text("只读") }
                Text("r\(browser.loadedRevision) · \(browser.items.count) 项").fixedSize()
            }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 12).frame(height: 28)
        }.frame(minWidth: 650)
    }
    private var previewPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(browser.selectedItem?.name ?? "文件预览").font(.system(size: 12, weight: .semibold))
                Spacer()
                Button { browser.closePreview() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).help("关闭预览").accessibilityLabel("关闭预览")
            }.padding(10)
            Divider()
            RepositoryPreview(text: browser.preview)
        }.frame(minWidth: 280, idealWidth: 360).background(Color(nsColor: .textBackgroundColor))
    }

}

private struct RepositoryPreview: View {
    let text: String
    var body: some View {
        GeometryReader { geometry in
        ScrollView([.horizontal, .vertical]) {
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { index, line in
                    HStack(alignment: .top, spacing: 14) {
                        Text("\(index + 1)").foregroundStyle(.tertiary).frame(width: 30, alignment: .trailing)
                        Text(line.isEmpty ? " " : line).fixedSize(horizontal: true, vertical: true)
                    }.font(.system(size: 12, design: .monospaced))
                }
            }.textSelection(.enabled).padding(16)
                .frame(minWidth: geometry.size.width, minHeight: geometry.size.height, alignment: .topLeading)
        }
        }
    }
}
