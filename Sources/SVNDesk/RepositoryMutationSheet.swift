import AppKit
import SwiftUI
import SVNCore

enum RepositoryMutationKind: String, Sendable {
    case upload = "上传到仓库", mkdir = "新建仓库目录", rename = "重命名仓库项目", delete = "删除仓库项目"
}
struct RepositoryMutationDraft: Identifiable, Sendable {
    let id = UUID()
    let kind: RepositoryMutationKind
    let directory: URL
    let revision: String
    let existing: [SVNRepositoryItem]
    let item: SVNRepositoryItem?
    var sources: [URL] = []
}

struct RepositoryMutationSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var browser: RepositoryBrowserModel
    let draft: RepositoryMutationDraft
    @State private var sources: [URL]
    @State private var name: String
    @State private var overwrite = false
    @State private var confirmDelete = false
    @State private var message = ""
    @State private var plan: RemoteMutationPlan?
    @State private var preparing = false
    @State private var error: String?
    private struct Inputs: Hashable { let sources: [URL]; let name: String; let overwrite: Bool }
    init(browser: RepositoryBrowserModel, draft: RepositoryMutationDraft) {
        self.browser = browser; self.draft = draft
        _sources = State(initialValue: draft.sources); _name = State(initialValue: draft.item?.name ?? "")
    }
    private var canCommit: Bool {
        plan != nil && !preparing && !browser.busy && !model.busy && !model.credentialBusy &&
        !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (draft.kind != .delete || confirmDelete)
    }
    private func chooseSources() {
        let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
        panel.message = "选择上传到当前仓库目录的文件或目录"; panel.prompt = "选择上传内容"
        if panel.runModal() == .OK { sources = panel.urls }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(draft.kind.rawValue, systemImage: draft.kind == .delete ? "trash" : "arrow.up.doc").font(.title2.weight(.semibold))
            Text(draft.directory.absoluteString).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).lineLimit(3)
            SavedCredentialPicker()
            if draft.kind == .upload {
                HStack {
                    Text("已选择 \(sources.count) 项").font(.callout)
                    Spacer(); Button("重新选择…") { chooseSources() }.disabled(browser.busy)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(sources, id: \.path) { url in
                            Text(url.path).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 90)
                Toggle("覆盖仓库中的同名文件", isOn: $overwrite).disabled(browser.busy)
                    .help("目录递归上传，保留空目录，忽略 .svn 和 .DS_Store；同名目录不合并，符号链接暂不支持。")
            } else if draft.kind == .mkdir || draft.kind == .rename {
                if let item = draft.item { Text("原名称：\(item.name)").font(.callout) }
                TextField(draft.kind == .mkdir ? "目录名称" : "新名称", text: $name).textFieldStyle(.roundedBorder).disabled(browser.busy)
            } else if let item = draft.item {
                Text(item.name).font(.headline)
                Toggle(item.isDirectory ? "确认删除这个目录及其全部内容" : "确认删除这个文件", isOn: $confirmDelete).disabled(browser.busy)
                Text("历史版本保留。").font(.caption).foregroundStyle(.secondary)
            }
            if preparing { HStack { ProgressView().controlSize(.small); Text("正在检查上传内容…").font(.caption) } }
            if let plan, draft.kind == .upload {
                Text("\(plan.fileCount) 个文件、\(plan.directoryCount) 个新目录")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("提交说明").font(.callout.weight(.medium))
            TextEditor(text: $message).font(.system(size: 13)).frame(height: 100).padding(6)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25))).disabled(browser.busy)
            if let error { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            Divider()
            HStack {
                Text("基准版本 r\(draft.revision)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if browser.busy { ProgressView().controlSize(.small); Button("取消操作") { model.client.cancelAll() } }
                Button("关闭", role: .cancel) { dismiss() }.disabled(browser.busy)
                Button(draft.kind == .delete ? "确认删除并提交" : "提交到仓库") {
                    guard let plan else { return }
                    Task {
                        error = nil
                        if await browser.commit(plan, draft: draft, message: message, model: model) { dismiss() }
                        else { error = browser.error }
                    }
                }.buttonStyle(.borderedProminent).tint(draft.kind == .delete ? Color.red : Color.accentColor).disabled(!canCommit)
            }
        }.padding(28).frame(width: 650).interactiveDismissDisabled(browser.busy)
            .task(id: Inputs(sources: sources, name: name, overwrite: overwrite)) {
                preparing = true; plan = nil; error = nil
                let sources = sources, name = name.trimmingCharacters(in: .whitespacesAndNewlines), overwrite = overwrite, draft = draft
                do {
                    let prepared = try await Task.detached(priority: .userInitiated) {
                        switch draft.kind {
                        case .upload: return try SVNRemoteMutation.upload(sources: sources, directory: draft.directory, existing: draft.existing, overwrite: overwrite)
                        case .mkdir: return try SVNRemoteMutation.createDirectory(name: name, directory: draft.directory, existing: draft.existing)
                        case .rename:
                            guard let item = draft.item else { throw SVNFailure("请选择要重命名的项目。") }
                            return try SVNRemoteMutation.rename(item: item, name: name, directory: draft.directory, existing: draft.existing)
                        case .delete:
                            guard let item = draft.item else { throw SVNFailure("请选择要删除的项目。") }
                            return try SVNRemoteMutation.delete(item: item, directory: draft.directory)
                        }
                    }.value
                    guard !Task.isCancelled else { return }
                    plan = prepared; preparing = false
                } catch {
                    guard !Task.isCancelled else { return }
                    self.error = error.localizedDescription; preparing = false
                }
            }
    }
}
