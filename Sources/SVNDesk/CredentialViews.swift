import SwiftUI
import SVNCore

struct SavedCredentialPicker: View {
    @EnvironmentObject var model: AppModel
    var showsLabel = true
    var showsError = true
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Picker(selection: Binding(get: { model.selectedCredentialID ?? "" }, set: { id in
                Task { await model.selectCredential(id.isEmpty ? nil : id) }
            })) {
                Text("使用 SVN 缓存").tag("")
                ForEach(model.savedCredentials) { profile in Text("\(profile.name) · \(profile.username)").lineLimit(1).truncationMode(.middle).tag(profile.id) }
            } label: { if showsLabel { Text("登录凭据") } }
                .pickerStyle(.menu).disabled(model.busy || model.credentialBusy)
                .help(model.savedCredentials.first { $0.id == model.selectedCredentialID }.map { "\($0.name) · \($0.username)" } ?? "使用 SVN 缓存")
            if showsError, let error = model.credentialError { Text(error).font(.caption).foregroundStyle(.orange) }
        }
    }
}

struct CredentialEditor: View {
    @EnvironmentObject var model: AppModel
    @State private var editingID: String?
    @State private var name = ""
    @State private var username = ""
    @State private var password = ""
    @State private var message: String?
    @State private var failed = false
    @State private var deleting = false
    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (editingID != nil || !password.isEmpty)
    }
    private func loadSelected() {
        editingID = model.selectedCredentialID
        let profile = model.savedCredentials.first { $0.id == editingID }
        name = profile?.name ?? ""; username = profile?.username ?? model.username
        password = ""; message = nil
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("已保存的凭据", systemImage: "key.fill").font(.headline)
            SavedCredentialPicker()
            Form {
                TextField("凭据名称", text: $name, prompt: Text("例如：公司 SVN"))
                TextField("用户名", text: $username)
                SecureField("密码", text: $password, prompt: Text(editingID == nil ? "输入密码" : "留空保留已保存的密码"))
            }.textFieldStyle(.roundedBorder)
            HStack {
                Button("新增凭据") { editingID = nil; name = ""; username = ""; password = ""; message = nil }
                Button(editingID == nil ? "保存并使用" : "保存修改") {
                    Task {
                        do {
                            try await model.saveCredential(id: editingID, name: name, username: username, password: password)
                            loadSelected(); failed = false; message = "已保存"
                        } catch { failed = true; message = error.localizedDescription }
                    }
                }.buttonStyle(.borderedProminent).disabled(!canSave)
                Spacer()
                if editingID != nil { Button("删除凭据", role: .destructive) { deleting = true } }
                if model.credentialBusy { ProgressView().controlSize(.small) }
            }
            if let message { Text(message).font(.caption).foregroundStyle(failed ? Color.orange : Color.green) }
            Text("密码保存在 macOS 钥匙串。")
                .font(.caption).foregroundStyle(.secondary)
        }.disabled(model.busy || model.credentialBusy)
            .onAppear { loadSelected() }
            .onChange(of: model.selectedCredentialID) { id in if id != editingID { loadSelected() } }
            .onChange(of: model.credentialBusy) { busy in if !busy && name.isEmpty { loadSelected() } }
            .alert("删除这组凭据？", isPresented: $deleting) {
                Button("取消", role: .cancel) {}
                Button("删除", role: .destructive) {
                    guard let id = editingID else { return }
                    Task {
                        do { try await model.deleteCredential(id); loadSelected(); failed = false; message = "凭据已删除。" }
                        catch { failed = true; message = error.localizedDescription }
                    }
                }
            } message: { Text("将删除名称、用户名和钥匙串中的密码；不会删除工作副本。") }
    }
}
