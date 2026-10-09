import SwiftUI
import SVNCore

private let accent = Color.accentColor

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var revertPaths: [String] = []
    @State private var resolveEntry: SVNEntry?
    @State private var showRevert = false
    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 210)
            Divider()
            if model.repositoryMode {
                RepositoryBrowserView().environmentObject(model)
            } else {
            VStack(spacing: 0) {
                header
                Divider()
                if model.current == nil { welcome }
                else {
                    HSplitView {
                        VStack(spacing: 0) {
                            Picker("视图", selection: $model.page) {
                                Text("工作区变更").tag("变更")
                                Text("提交历史").tag("历史")
                                Text("操作记录").tag("记录")
                            }.pickerStyle(.segmented).padding(16)
                            if model.page == "变更" { changesView }
                            else if model.page == "历史" { historyView }
                            else { activityView }
                        }.frame(minWidth: 420, idealWidth: 560)
                        inspector.frame(minWidth: 300, idealWidth: 440)
                    }
                }
                Divider()
                statusBar
            }.background(Color(nsColor: .windowBackgroundColor))
            }
        }
        .tint(accent)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { model.openFolder() } label: { Label("添加工作副本", systemImage: "folder.badge.plus") }.disabled(model.busy)
                Button { model.presentCheckout() } label: { Label("检出", systemImage: "arrow.down.to.line") }.disabled(model.busy)
                if !model.repositoryMode {
                    Divider()
                    Button { Task { await model.refresh() } } label: { Label("刷新", systemImage: "arrow.clockwise") }.disabled(model.current == nil || model.busy)
                    Button { Task { await model.update() } } label: { Label("更新", systemImage: "arrow.down.circle") }.disabled(model.current == nil || model.busy)
                }
            }
        }
        .sheet(isPresented: $model.showCheckout) { CheckoutSheet().environmentObject(model) }
        .sheet(isPresented: $model.showCommit) { CommitSheet().environmentObject(model) }
        .sheet(isPresented: $model.showSettings) { SettingsSheet().environmentObject(model) }
        .alert("操作未完成", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("确定") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
        .alert("撤销本地修改？", isPresented: $showRevert) {
            Button("取消", role: .cancel) {}
            Button("撤销修改", role: .destructive) { let paths = revertPaths; Task { await model.revert(paths) } }
        } message: { Text("将撤销所选 \(revertPaths.count) 项及其子目录的本地修改，未提交的内容无法恢复。新增文件会保留在磁盘上。") }
        .alert("确认冲突已经处理？", isPresented: Binding(get: { resolveEntry != nil }, set: { if !$0 { resolveEntry = nil } })) {
            Button("取消", role: .cancel) { resolveEntry = nil }
            Button("标记已解决") { if let entry = resolveEntry { Task { await model.resolve(entry) } }; resolveEntry = nil }
        } message: { Text("请先编辑文件、确认冲突标记已清除。应用将保留当前文件内容，并移除 SVN 冲突状态。") }
        .onChange(of: model.selectedFile) { _ in Task { await model.loadDiff() } }
        .onChange(of: model.page) { value in if value == "历史" { Task { await model.loadLogs() } } }
        .onChange(of: model.selectedLog) { value in if let value { Task { await model.revisionDiff(value) } } }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { model.repositoryMode = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: "externaldrive").frame(width: 18)
                    Text("仓库浏览器")
                    Spacer(minLength: 0)
                }.padding(8).background(model.repositoryMode ? accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 5))
            }.buttonStyle(.plain).padding(8).disabled(model.busy)
            HStack {
                Text("工作副本").font(.system(size: 11, weight: .medium))
                Spacer(); Text("\(model.copies.count)").font(.caption)
            }.foregroundStyle(.secondary).padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 6)
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(model.copies) { copy in
                        Button { model.repositoryMode = false; model.selectedCopy = copy.id } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "folder").frame(width: 18).foregroundStyle(.secondary)
                                Text(copy.name).lineLimit(1)
                                Spacer(minLength: 0)
                            }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                                .background(!model.repositoryMode && model.selectedCopy == copy.id ? accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 5))
                        }.buttonStyle(.plain).disabled(model.busy)
                            .contextMenu {
                                Button("在 Finder 中显示") { model.revealCopy(copy) }
                                Button("从列表移除", role: .destructive) { model.removeCopy(copy) }.disabled(model.busy)
                            }.help(copy.path)
                    }
                }.padding(.horizontal, 8)
            }
            Divider()
            HStack {
                Button { model.openFolder() } label: { Label("添加", systemImage: "plus") }.buttonStyle(.plain).disabled(model.busy).help("添加工作副本")
                Spacer()
                if model.binary == nil { Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange).help("未安装 SVN") }
                Button { model.showSettings = true } label: { Image(systemName: "gearshape") }.disabled(model.busy).buttonStyle(.plain).help("设置")
            }.padding(12)
        }.font(.system(size: 13)).background(Color(nsColor: .underPageBackgroundColor))
    }
    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.current?.name ?? "工作副本").font(.system(size: 14, weight: .semibold))
                if let url = model.info?.url { Text(url)
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).textSelection(.enabled)
                }
            }
            Spacer(minLength: 20)
            if let info = model.info {
                Text("r\(info.revision)").font(.system(size: 12, weight: .medium, design: .monospaced)).padding(.horizontal, 10).padding(.vertical, 6).background(accent.opacity(0.08), in: Capsule()).foregroundStyle(accent)
            }
            Button { model.showCommit = true } label: {
                Label(model.commitEntries.isEmpty ? "提交变更" : "提交 \(model.commitEntries.count) 项", systemImage: "arrow.up.circle.fill").padding(.horizontal, 8).padding(.vertical, 5)
            }.buttonStyle(.borderedProminent).disabled(model.busy || model.commitEntries.isEmpty)
        }.padding(12)
    }
    private var welcome: some View {
        VStack(spacing: 16) {
            Text("未添加工作副本").foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button("添加本地工作副本") { model.openFolder() }.buttonStyle(.borderedProminent).controlSize(.large)
                Button("检出仓库…") { model.presentCheckout() }.buttonStyle(.bordered).controlSize(.large)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private var changesView: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                metric("变更", count: model.changes.count, color: accent)
                metric("可提交", count: model.changes.filter(\.canCommit).count, color: .blue)
                metric("冲突", count: model.changes.filter(\.isConflict).count, color: .orange)
                Spacer()
            }.padding(.horizontal, 18).padding(.bottom, 18)
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索文件路径", text: $model.search).textFieldStyle(.plain)
                Picker("筛选", selection: $model.filter) {
                    ForEach(["全部", "可提交", "未跟踪", "冲突"], id: \.self) { Text($0) }
                }.labelsHidden().frame(width: 110)
            }.padding(.horizontal, 14).padding(.vertical, 8).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7)).padding(.horizontal, 16).padding(.bottom, 12)
            if model.visibleEntries.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: model.changes.isEmpty ? "checkmark.circle" : "line.3.horizontal.decrease.circle").font(.system(size: 38, weight: .light)).foregroundStyle(accent)
                    Text(model.changes.isEmpty ? "无本地变更" : "没有匹配的文件").foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(model.visibleEntries, selection: $model.selectedFile) {
                    TableColumn("") { entry in
                        Toggle("选择 \(entry.path)", isOn: Binding(get: { model.checked.contains(entry.path) }, set: { value in if value { model.checked.insert(entry.path) } else { model.checked.remove(entry.path) } }))
                            .labelsHidden().toggleStyle(.checkbox).disabled(!entry.canCommit || model.busy)
                    }.width(24)
                    TableColumn("文件") { entry in
                        HStack(spacing: 8) {
                            Image(systemName: "doc.text").foregroundStyle(.secondary)
                            Text(entry.path).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                        }.help(entry.path)
                            .contextMenu { fileMenu(entry) }
                    }.width(min: 180, ideal: 320)
                    TableColumn("状态") { entry in statusBadge(entry) }.width(80)
                }.disabled(model.busy)
            }
            Divider()
            HStack {
                Button("选择可提交项") { model.chooseAll() }.buttonStyle(.link).disabled(model.busy)
                Button("清空选择") { model.checked = [] }.buttonStyle(.link).disabled(model.checked.isEmpty || model.busy)
                Spacer()
                Text("已选 \(model.commitEntries.count) 项").font(.caption).foregroundStyle(.secondary)
            }.padding(14)
        }
    }
    private func metric(_ title: String, count: Int, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(count)").font(.system(size: 26, weight: .medium, design: .rounded)).foregroundStyle(color)
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func statusBadge(_ entry: SVNEntry) -> some View {
        let color: Color = entry.isConflict ? .orange : entry.status == "deleted" || entry.status == "missing" ? .red : entry.status == "unversioned" ? .secondary : accent
        return Text(entry.title).font(.system(size: 10, weight: .medium)).padding(.horizontal, 7).padding(.vertical, 4).background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: 4)).foregroundStyle(color)
    }
    @ViewBuilder private func fileMenu(_ entry: SVNEntry) -> some View {
        Button("查看差异") { model.selectedFile = entry.path; Task { await model.loadDiff() } }.disabled(model.busy)
        Button("用默认程序打开") { model.openFile(entry) }
        Button("在 Finder 中显示") { model.reveal(entry.path) }
        Divider()
        if entry.status == "unversioned" || entry.status == "missing" {
            Button(entry.status == "unversioned" ? "加入版本控制" : "登记为删除") { Task { await model.stage(entry) } }.disabled(model.busy)
        }
        if entry.isConflict { Button("标记冲突已解决…") { resolveEntry = entry }.disabled(model.busy) }
        if entry.status != "unversioned" && entry.status != "external" {
            Button("撤销本地修改…", role: .destructive) { revertPaths = [entry.path]; showRevert = true }.disabled(model.busy)
        }
    }
    private var historyView: some View {
        VStack(spacing: 0) {
            HStack { Text("最近 100 次提交").font(.caption).foregroundStyle(.secondary); Spacer(); Button("重新读取") { Task { await model.loadLogs() } }.disabled(model.busy) }.padding(.horizontal, 16).padding(.bottom, 12)
            List(model.logs, selection: $model.selectedLog) { log in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("r\(log.revision)").font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundStyle(accent)
                        Text(log.author.isEmpty ? "未知作者" : log.author).font(.caption)
                        Spacer(); Text(String(log.date.prefix(10))).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(log.message.isEmpty ? "无提交说明" : log.message).font(.system(size: 12)).lineLimit(3)
                    Text("\(log.paths.count) 个路径").font(.system(size: 10)).foregroundStyle(.tertiary)
                }.padding(.vertical, 8).tag(log.id)
            }.listStyle(.inset).disabled(model.busy)
        }
    }
    private var activityView: some View {
        List(model.activities) { activity in
            DisclosureGroup {
                Text(activity.output).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
            } label: {
                HStack { Image(systemName: activity.failed ? "exclamationmark.circle" : "checkmark.circle").foregroundStyle(activity.failed ? .red : accent); Text(activity.title); Spacer(); Text(activity.date, style: .time).foregroundStyle(.secondary).font(.caption) }
            }.padding(.vertical, 6)
        }.listStyle(.inset)
    }
    private var inspector: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label(model.page == "历史" ? "版本差异" : "文件差异", systemImage: "text.alignleft").font(.system(size: 12, weight: .semibold))
                Spacer()
                if let entry = model.selectedEntry, model.page == "变更" { Menu { fileMenu(entry) } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).frame(width: 24) }
            }.padding(17)
            Divider()
            if let entry = model.selectedEntry, model.page == "变更" {
                HStack { Text(entry.path).font(.system(size: 11, design: .monospaced)).lineLimit(2).textSelection(.enabled); Spacer(); statusBadge(entry) }.padding(16)
                Divider()
            }
            if (model.page == "变更" && model.selectedFile == nil) || (model.page == "历史" && model.selectedLog == nil) || model.page == "记录" {
                VStack(spacing: 12) {
                    Image(systemName: "doc.text.magnifyingglass").font(.system(size: 34, weight: .ultraLight))
                    Text(model.page == "历史" ? "未选择提交" : "未选择文件").font(.system(size: 12))
                }.foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else { DiffView(text: model.page == "历史" ? model.historyDiff : model.diff) }
        }.background(Color(nsColor: .textBackgroundColor))
    }
    private var statusBar: some View {
        HStack(spacing: 8) {
            if model.busy {
                ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 14, height: 14)
                Text(model.busyTitle).font(.system(size: 11))
                Button("取消") { model.client.cancelAll() }.buttonStyle(.link).font(.caption)
            } else {
                Image(systemName: "circle.fill").font(.system(size: 6)).foregroundStyle(accent)
                Text("就绪").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Text(model.current?.path ?? "SVN Desk \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.2")").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            if model.current != nil { Button { model.reveal() } label: { Image(systemName: "folder") }.buttonStyle(.plain).help("在 Finder 中显示") }
        }.padding(.horizontal, 18).frame(height: 32)
    }
}

struct DiffView: View {
    let text: String
    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { index, line in
                    HStack(alignment: .top, spacing: 14) {
                        Text("\(index + 1)").foregroundStyle(.tertiary).frame(width: 35, alignment: .trailing)
                        Text(line.isEmpty ? " " : line).foregroundStyle(line.hasPrefix("+") ? Color(red: 0.12, green: 0.58, blue: 0.35) : line.hasPrefix("-") ? .red : line.hasPrefix("@@") ? .blue : .primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.font(.system(size: 11, design: .monospaced)).padding(.vertical, 3).padding(.horizontal, 12)
                        .background(line.hasPrefix("+") ? Color.green.opacity(0.055) : line.hasPrefix("-") ? Color.red.opacity(0.055) : .clear)
                }
            }.textSelection(.enabled).padding(.vertical, 10)
        }
    }
}
