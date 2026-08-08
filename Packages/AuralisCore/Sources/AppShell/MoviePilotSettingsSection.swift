import Application
import SecurityKit
import SwiftUI

/// 设置页「音乐下载（MoviePilot）」配置区块（iOS / macOS 共用）。
/// Base URL 存 UserDefaults；调用 Token 只存 Keychain（不落盘明文）。
struct MoviePilotSettingsSection: View {
    @AppStorage(MoviePilotSettings.baseURLKey) private var baseURL = ""
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
            Text("音乐下载（MoviePilot）")
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
        if let value = try? await vault.retrieve(id: MoviePilotSettings.tokenCredentialID) {
            token = value
        }
    }

    private func persistToken() {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            let vault = KeychainCredentialVault()
            if trimmed.isEmpty {
                try? await vault.delete(id: MoviePilotSettings.tokenCredentialID)
            } else {
                try? await vault.store(trimmed, for: MoviePilotSettings.tokenCredentialID)
            }
        }
    }

    private func testConnection() async {
        isTesting = true
        defer { isTesting = false }
        let settings = MoviePilotSettings()
        guard let url = settings.normalizedURL else {
            testResult = "请先填写合法的服务器地址"
            return
        }
        var storedToken: String?
        if let value = try? await KeychainCredentialVault().retrieve(id: MoviePilotSettings.tokenCredentialID) {
            storedToken = value
        }
        let connection = MoviePilotConnection(baseURL: url, token: storedToken)
        do {
            // 走插件 v0.4.8+ 的 /test 接口：逐项返回插件启用/目录/站点/下载器/元数据服务。
            let data = try await MoviePilotClient().test(connection)
            let checks = (data.checks ?? []).map { check in
                let ok = check.ok == true
                let name = check.name ?? "检查项"
                let detail = check.detail ?? ""
                return "\(ok ? "✅" : "❌") \(name)\(detail.isEmpty ? "" : "：\(detail)")"
            }
            let summary = data.summary ?? (checks.contains(where: { !$0.hasPrefix("✅") }) ? "部分未通过" : "全部通过")
            testResult = ([summary] + checks).joined(separator: "\n")
        } catch {
            testResult = "连接失败：\(error.localizedDescription)"
        }
    }
}
