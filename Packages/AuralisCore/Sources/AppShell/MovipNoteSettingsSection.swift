import Application
import SecurityKit
import SwiftUI

/// 设置页「音乐下载（MovipNote）」配置区块（iOS / macOS 共用）。
/// Base URL 存 UserDefaults；调用 Token 只存 Keychain（不落盘明文）。
struct MovipNoteSettingsSection: View {
    @AppStorage(MovipNoteSettings.baseURLKey) private var baseURL = ""
    @State private var token = ""
    @State private var testResult: String?
    @State private var isTesting = false

    var body: some View {
        Section {
            TextField("服务器地址（如 http://192.168.1.10:3000）", text: $baseURL)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .autocorrectionDisabled()
                .onChange(of: baseURL) { testResult = nil }
            SecureField("调用 Token（插件的 X-Music-Token）", text: $token)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .autocorrectionDisabled()
                .onChange(of: token) {
                    persistToken()
                    testResult = nil
                }
            Button(isTesting ? "测试中…" : "测试连接") {
                Task { await testConnection() }
            }
            .disabled(isTesting)
            if let testResult {
                Text(testResult)
                    .font(.caption)
                    .foregroundStyle(secondaryText)
            }
        } header: {
            Text("音乐下载（MovipNote）")
        } footer: {
            Text("在 MoviePilot 安装「音乐下载」插件后填写地址与 Token。Agent 说「下载某首歌/某个专辑」或点播不在库中的歌曲时，会通过它搜索并下载到 NAS 音乐目录（仅下载，不刮削/整理）。")
        }
        .task {
            await loadToken()
        }
    }

    private var secondaryText: Color {
        #if os(iOS)
        .secondary
        #else
        .secondary
        #endif
    }

    private func loadToken() async {
        let vault = KeychainCredentialVault()
        if let value = try? await vault.retrieve(id: MovipNoteSettings.tokenCredentialID) {
            token = value
        }
    }

    private func persistToken() {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            let vault = KeychainCredentialVault()
            if trimmed.isEmpty {
                try? await vault.delete(id: MovipNoteSettings.tokenCredentialID)
            } else {
                try? await vault.store(trimmed, for: MovipNoteSettings.tokenCredentialID)
            }
        }
    }

    private func testConnection() async {
        isTesting = true
        defer { isTesting = false }
        let settings = MovipNoteSettings()
        guard let url = settings.normalizedURL else {
            testResult = "请先填写合法的服务器地址"
            return
        }
        var storedToken: String?
        if let value = try? await KeychainCredentialVault().retrieve(id: MovipNoteSettings.tokenCredentialID) {
            storedToken = value
        }
        let connection = MovipNoteConnection(baseURL: url, token: storedToken)
        do {
            let sites = try await MovipNoteClient().sites(connection)
            let names = (sites.sites ?? []).compactMap(\.name)
            testResult = "连接成功 · 模式 \(sites.mode ?? "all")\(names.isEmpty ? "" : " · 站点：\(names.prefix(6).joined(separator: "、"))\(names.count > 6 ? " 等 \(names.count) 个" : "")")"
        } catch {
            testResult = "连接失败：\(error.localizedDescription)"
        }
    }
}
