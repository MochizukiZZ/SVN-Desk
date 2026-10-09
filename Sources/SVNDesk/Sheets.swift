import AppKit
import SwiftUI
import SVNCore

struct CheckoutSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @State private var repository = ""
    @State private var revision = "HEAD"
    @State private var parent = NSHomeDirectory() + "/Projects"
    @State private var folder = ""
    @State private var manageCredentials = false
    var destination: String { URL(fileURLWithPath: parent).appendingPathComponent(folder).path }
    var valid: Bool { !repository.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !folder.isEmpty && folder != "." && folder != ".." && !folder.contains("/") && !parent.isEmpty }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("检出仓库", systemImage: "arrow.down.to.line").font(.title2.weight(.semibold))
            Form {
                TextField("仓库 URL", text: $repository, prompt: Text("https://svn.example.com/project/trunk"))
                TextField("检出版本", text: $revision)
                HStack {
                    TextField("保存位置", text: $parent)
                    Button("选择…") {
                        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
                        if panel.runModal() == .OK, let url = panel.url { parent = url.path }
                    }
                }
                TextField("新目录名称", text: $folder, prompt: Text("项目名称"))
            }.textFieldStyle(.roundedBorder)
            HStack {
                SavedCredentialPicker()
                Button("管理凭据…") { manageCredentials = true }
            }
            Text(destination).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
            Divider()
            HStack {
                Spacer()
                if model.busy { ProgressView().controlSize(.small); Button("取消操作") { model.client.cancelAll() } }
                Button("关闭", role: .cancel) { dismiss() }.disabled(model.busy)
                Button("检出") {
                    let url = repository.trimmingCharacters(in: .whitespacesAndNewlines)
                    if FileManager.default.fileExists(atPath: destination) { model.errorMessage = "目标目录已经存在，请使用新的目录名称。"; return }
                    Task { await model.checkout(url: url, destination: destination, revision: revision) }
                }.buttonStyle(.borderedProminent).disabled(!valid || model.busy || model.credentialBusy)
            }
        }.padding(28).frame(width: 580).interactiveDismissDisabled(model.busy)
            .sheet(isPresented: $manageCredentials) { SettingsSheet().environmentObject(model) }
            .onAppear {
                repository = model.checkoutSeedURL; revision = model.checkoutSeedRevision
                if let url = URL(string: repository), !url.lastPathComponent.isEmpty { folder = url.lastPathComponent }
            }
    }
}
struct CommitSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @State private var message = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("提交 \(model.commitEntries.count) 项变更", systemImage: "arrow.up.circle").font(.title2.weight(.semibold))
            Text("提交说明").font(.callout)
            TextEditor(text: $message).font(.system(size: 13)).frame(height: 130).padding(6).overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2)))
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(model.commitEntries) { entry in
                        HStack { Text(entry.title).font(.caption).foregroundStyle(.secondary).frame(width: 60, alignment: .leading); Text(entry.path).font(.system(size: 11, design: .monospaced)); Spacer() }
                    }
                }.padding(12)
            }.frame(maxHeight: 170).background(Color.secondary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
            Divider()
            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                Button("提交到仓库") { Task { await model.commit(message) } }.buttonStyle(.borderedProminent)
                    .disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.commitEntries.isEmpty || model.busy)
            }
        }.padding(28).frame(width: 600)
    }
}
struct SettingsSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Label("设置", systemImage: "gearshape").font(.title2.weight(.semibold))
            ScrollView {
            VStack(alignment: .leading, spacing: 20) {
            Form {
                TextField("SVN 路径", text: $model.binaryPath, prompt: Text("自动查找 Homebrew 或系统路径"))
            }.textFieldStyle(.roundedBorder)
            CredentialEditor()
            VStack(alignment: .leading, spacing: 9) {
                Label(model.binary == nil ? "未检测到可用 SVN" : "\(model.binary!)", systemImage: model.binary == nil ? "exclamationmark.circle" : "checkmark.circle").foregroundStyle(model.binary == nil ? Color.orange : Color.green)
                if model.binary == nil { Text("brew install subversion").textSelection(.enabled) }
                DisclosureGroup("工具信息") {
                    Text("svnmucc：\(SVNRemoteMutation.executable(svn: model.binary) ?? "未安装")").textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    Text("SVN 1.10+；证书与 SSH 信任使用本机配置。").frame(maxWidth: .infinity, alignment: .leading)
                }
            }.font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(4)
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Label("Finder 扩展", systemImage: "folder.badge.gearshape").font(.headline)
                Button("管理 Finder 扩展…") { FinderBridge.showManagement() }.help("为已添加的工作副本显示角标和右键菜单。多个扩展可能争用角标。")
            }
            }
            }.frame(maxHeight: 590)
            Divider()
            HStack {
                Spacer(); Button("完成") { dismiss() }.buttonStyle(.borderedProminent)
            }
        }.padding(28).frame(width: 620)
    }
}
