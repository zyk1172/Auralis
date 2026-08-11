import Application
import DesignSystem
import Domain
import Foundation
import SecurityKit
import SwiftUI
import ThemeEngine

/// 「备份与恢复」区块：放在大模型（OpenAI 兼容接口）设置下面。
/// 导出 = 密码加密生成备份文件（分享 / 保存）；
/// 恢复 = 选择备份文件 + 输入密码，写回服务器、大模型与其他设置。
/// 只备份配置，不包含歌曲、歌单、收藏与播放记录等音乐资料。
///
/// iOS 呈现策略：行内按钮只发出明确 route，真正的 sheet 由 `DataSettingsPage`
/// 在 Form 外层呈现。这样按钮不会依赖嵌套 NavigationLink，也不会让 fileImporter
/// 与 Form 行状态在首次点击时互相撤销。
/// macOS 设置窗口用 TabView+Form，sheet 行为稳定，保留原 sheet 方案。
struct SettingsBackupSection: View {
    @ObservedObject var model: AuralisAppModel
    @ObservedObject var themeStore: ThemeStore
    let theme: BuiltInTheme
    var onExport: (() -> Void)? = nil
    var onImport: (() -> Void)? = nil

    // macOS 专用呈现状态
    @State private var isExportSheetPresented = false
    @State private var isImportSheetPresented = false
    @State private var isImportPasswordSheetPresented = false
    @State private var exportPassword = ""
    @State private var generatedBackupURL: URL?
    @State private var isGenerating = false
    @State private var exportError: String?
    @State private var importPassword = ""
    @State private var importFileURL: URL?
    @State private var isRestoring = false
    @State private var restoreError: String?

    private let service = SettingsBackupService()
    private let credentialVault = KeychainCredentialVault()

    var body: some View {
        Section("备份与恢复") {
#if os(iOS)
            Button {
                onExport?()
            } label: {
                Label("导出备份…", systemImage: "square.and.arrow.up")
            }
            Button {
                onImport?()
            } label: {
                Label("从备份恢复…", systemImage: "square.and.arrow.down")
            }
#else
            Button {
                presentExport()
            } label: {
                Label("导出备份…", systemImage: "square.and.arrow.up")
            }
            Button {
                presentImport()
            } label: {
                Label("从备份恢复…", systemImage: "square.and.arrow.down")
            }
#endif
            Text("备份内容：App 设置、音乐服务器（含登录凭据）、大模型接口、音乐下载插件（含 Token）。不包含本地数据库、歌曲、专辑、歌单、收藏、播放记录、缓存或下载文件。备份文件使用密码加密，请妥善保管密码。")
                .font(.caption)
                .foregroundStyle(theme.colorTokens.secondaryText.color)
        }
#if !os(iOS)
        .sheet(isPresented: $isExportSheetPresented) {
            exportSheet
        }
        .fileImporter(
            isPresented: $isImportSheetPresented,
            allowedContentTypes: [.data],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case let .success(urls):
                guard let url = urls.first else { return }
                importFileURL = url
                importPassword = ""
                restoreError = nil
                isImportPasswordSheetPresented = true
            case let .failure(error):
                restoreError = "无法读取备份文件：\(error.localizedDescription)"
            }
        }
        .sheet(isPresented: $isImportPasswordSheetPresented) {
            importPasswordSheet
        }
#endif
    }

    // MARK: macOS 呈现

    private func presentExport() {
        exportPassword = ""
        exportError = nil
        generatedBackupURL = nil
        DispatchQueue.main.async {
            self.isExportSheetPresented = true
        }
    }

    private func presentImport() {
        restoreError = nil
        DispatchQueue.main.async {
            self.isImportSheetPresented = true
        }
    }

    // MARK: macOS 导出

    private var exportSheet: some View {
        NavigationStack {
            Form {
                if let url = generatedBackupURL {
                    Section {
                        ShareLink(item: url) {
                            Label("分享 / 保存备份文件", systemImage: "square.and.arrow.up")
                        }
                        Text("备份已加密生成。请保存到「文件」或其它安全位置；恢复时需要同一密码。")
                            .font(.caption)
                            .foregroundStyle(theme.colorTokens.secondaryText.color)
                    }
                } else {
                    Section("导出备份") {
                        SecureField("备份密码（至少 8 位，建议混合大小写与数字）", text: $exportPassword)
                        Text("恢复时需要同一密码。密码不会被保存。")
                            .font(.caption)
                            .foregroundStyle(theme.colorTokens.secondaryText.color)
                        Button {
                            Task { await generateBackup() }
                        } label: {
                            if isGenerating {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("生成备份")
                            }
                        }
                        .disabled(isGenerating || exportPassword.count < 8)
                        if let exportError {
                            Label(exportError, systemImage: "xmark.octagon.fill")
                                .font(.caption)
                                .foregroundStyle(theme.colorTokens.error.color)
                        }
                    }
                }
            }
            .navigationTitle("导出备份")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        isExportSheetPresented = false
                        generatedBackupURL = nil
                        exportPassword = ""
                    }
                }
            }
        }
    }

    private func generateBackup() async {
        isGenerating = true
        exportError = nil
        defer { isGenerating = false }
        do {
            let servers = (try? await model.catalogCoordinator.store.listServers()) ?? []
            let backup = await Self.makeBackupPayload(servers: servers)
            let data = try service.encrypt(backup, password: exportPassword)
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("Auralis设置备份-\(Self.dateStamp()).auralisbackup")
            try data.write(to: url, options: .atomic)
            generatedBackupURL = url
        } catch {
            exportError = error.localizedDescription
        }
    }

    // MARK: macOS 恢复

    private var importPasswordSheet: some View {
        NavigationStack {
            Form {
                Section("恢复备份") {
                    SecureField("备份密码", text: $importPassword)
                    if let url = importFileURL {
                        LabeledContent("备份文件", value: url.lastPathComponent)
                    }
                    Text("将恢复：App 设置、音乐服务器、大模型与音乐下载配置。不会覆盖或删除本地数据库、歌曲、歌单、收藏、播放记录、缓存或下载文件。")
                        .font(.caption)
                        .foregroundStyle(theme.colorTokens.secondaryText.color)
                    Button {
                        Task { await restoreBackup() }
                    } label: {
                        if isRestoring {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("恢复")
                        }
                    }
                    .disabled(isRestoring || importPassword.count < 8)
                    if let restoreError {
                        Label(restoreError, systemImage: "xmark.octagon.fill")
                            .font(.caption)
                            .foregroundStyle(theme.colorTokens.error.color)
                    }
                }
            }
            .navigationTitle("从备份恢复")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        isImportPasswordSheetPresented = false
                        importFileURL = nil
                        importPassword = ""
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        isImportPasswordSheetPresented = false
                        importFileURL = nil
                        importPassword = ""
                    }
                }
            }
        }
    }

    private func restoreBackup() async {
        guard let url = importFileURL else { return }
        isRestoring = true
        restoreError = nil
        defer { isRestoring = false }
        do {
            let accessing = url.startAccessingSecurityScopedResource()
            defer {
                if accessing { url.stopAccessingSecurityScopedResource() }
            }
            let data = try Data(contentsOf: url)
            let backup = try service.decrypt(data, password: importPassword)
            await Self.applyBackup(backup, model: model, themeStore: themeStore, vault: credentialVault)
            restoreError = "恢复完成。服务器不会自动同步，请在「服务器」中手动连接。"
        } catch {
            restoreError = error.localizedDescription
        }
    }

    // MARK: 共享

    /// 收集备份内容：服务器账号 + 登录凭据（Keychain）、大模型配置 + API Key（Keychain）、
    /// 以及其他白名单设置（UserDefaults）。不触碰任何歌曲相关资料。
    fileprivate static func makeBackupPayload(servers: [ServerAccount]) async -> SettingsBackup {
        let vault = KeychainCredentialVault()
        var backupServers: [BackupServer] = []
        for server in servers {
            var secret: String?
            if let reference = server.credentialReference {
                secret = try? await vault.retrieve(id: CredentialID(rawValue: reference))
            }
            backupServers.append(BackupServer(account: server, secret: secret))
        }
        let ai = AIConnectionSettings()
        let aiKey = try? await vault.retrieve(id: AIConnectionSettings.credentialID)
        let download = MoviePilotSettings()
        let downloadToken = try? await vault.retrieve(id: MoviePilotSettings.tokenCredentialID)
        return SettingsBackup(
            createdAt: Date(),
            servers: backupServers,
            ai: BackupAISettings(
                baseURL: ai.baseURL,
                apiPath: ai.apiPath,
                model: ai.model,
                apiKey: aiKey
            ),
            musicDownload: BackupMusicDownloadSettings(
                baseURL: download.baseURL,
                externalBaseURL: download.externalBaseURL,
                token: downloadToken
            ),
            preferences: SettingsBackupService.collectedPreferences(from: .standard)
        )
    }

    /// 写回备份：普通设置 + 大模型配置 + API Key + 主题 + 服务器账号（不联网、不触发资料同步）。
    fileprivate static func applyBackup(
        _ backup: SettingsBackup,
        model: AuralisAppModel,
        themeStore: ThemeStore,
        vault: KeychainCredentialVault
    ) async {
        SettingsBackupService.writePreferences(backup.preferences, defaults: .standard)
        let defaults = UserDefaults.standard
        defaults.set(backup.ai.baseURL, forKey: AIConnectionSettings.Keys.baseURL)
        defaults.set(backup.ai.apiPath, forKey: AIConnectionSettings.Keys.apiPath)
        defaults.set(backup.ai.model, forKey: AIConnectionSettings.Keys.model)

        if let apiKey = backup.ai.apiKey, !apiKey.isEmpty {
            try? await vault.store(apiKey, for: AIConnectionSettings.credentialID)
        }
        if let download = backup.musicDownload {
            defaults.set(download.baseURL, forKey: MoviePilotSettings.baseURLKey)
            defaults.set(download.externalBaseURL, forKey: MoviePilotSettings.externalBaseURLKey)
            if let token = download.token, !token.isEmpty {
                try? await vault.store(token, for: MoviePilotSettings.tokenCredentialID)
            }
        }
        if let themeID = backup.preferences["auralis.selected-theme"] {
            await MainActor.run { themeStore.select(id: themeID) }
        }
        for entry in backup.servers {
            await model.restoreServerAccountFromBackup(entry.account, secret: entry.secret)
        }
    }

    fileprivate static func dateStamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}

// MARK: - iOS 导出页（推入整页，避免 Form 行内弹 sheet 首击失效）

#if os(iOS)
struct BackupExportPage: View {
    @ObservedObject var model: AuralisAppModel
    @ObservedObject var themeStore: ThemeStore
    let theme: BuiltInTheme
    @Environment(\.dismiss) private var dismiss

    @State private var exportPassword = ""
    @State private var generatedBackupURL: URL?
    @State private var isGenerating = false
    @State private var exportError: String?

    private let service = SettingsBackupService()

    var body: some View {
        Form {
            if let url = generatedBackupURL {
                Section {
                    ShareLink(item: url) {
                        Label("分享 / 保存备份文件", systemImage: "square.and.arrow.up")
                    }
                    Text("备份已加密生成。请保存到「文件」或其它安全位置；恢复时需要同一密码。")
                        .font(.caption)
                        .foregroundStyle(theme.colorTokens.secondaryText.color)
                }
            } else {
                Section("导出备份") {
                    SecureField("备份密码（至少 8 位，建议混合大小写与数字）", text: $exportPassword)
                    Text("恢复时需要同一密码。密码不会被保存。")
                        .font(.caption)
                        .foregroundStyle(theme.colorTokens.secondaryText.color)
                    Button {
                        Task { await generateBackup() }
                    } label: {
                        if isGenerating {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("生成备份")
                        }
                    }
                    .disabled(isGenerating || exportPassword.count < 8)
                    if let exportError {
                        Label(exportError, systemImage: "xmark.octagon.fill")
                            .font(.caption)
                            .foregroundStyle(theme.colorTokens.error.color)
                    }
                }
            }
        }
        .navigationTitle("导出备份")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("完成") { dismiss() }
            }
        }
    }

    private func generateBackup() async {
        isGenerating = true
        exportError = nil
        defer { isGenerating = false }
        do {
            let servers = (try? await model.catalogCoordinator.store.listServers()) ?? []
            let backup = await SettingsBackupSection.makeBackupPayload(servers: servers)
            let data = try service.encrypt(backup, password: exportPassword)
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("Auralis设置备份-\(SettingsBackupSection.dateStamp()).auralisbackup")
            try data.write(to: url, options: .atomic)
            generatedBackupURL = url
        } catch {
            exportError = error.localizedDescription
        }
    }
}

// MARK: - iOS 恢复页（推入整页）

struct BackupImportPage: View {
    @ObservedObject var model: AuralisAppModel
    @ObservedObject var themeStore: ThemeStore
    let theme: BuiltInTheme
    @Environment(\.dismiss) private var dismiss

    @State private var isFilePickerPresented = false
    @State private var importFileURL: URL?
    @State private var importPassword = ""
    @State private var isRestoring = false
    @State private var restoreMessage: String?
    @State private var restoreError: String?

    private let service = SettingsBackupService()
    private let credentialVault = KeychainCredentialVault()

    var body: some View {
        Form {
            Section("恢复备份") {
                Button {
                    isFilePickerPresented = true
                } label: {
                    if let url = importFileURL {
                        Label("已选择：\(url.lastPathComponent)", systemImage: "doc.fill")
                    } else {
                        Label("选择备份文件…", systemImage: "folder")
                    }
                }
                if importFileURL != nil {
                    SecureField("备份密码", text: $importPassword)
                    Text("将恢复：服务器信息、大模型配置与其他设置。不会覆盖或删除歌曲、歌单、收藏与播放记录。")
                        .font(.caption)
                        .foregroundStyle(theme.colorTokens.secondaryText.color)
                    Button {
                        Task { await restoreBackup() }
                    } label: {
                        if isRestoring {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("恢复")
                        }
                    }
                    .disabled(isRestoring || importPassword.count < 8)
                    if let restoreMessage {
                        Label(restoreMessage, systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(theme.colorTokens.success.color)
                    }
                    if let restoreError {
                        Label(restoreError, systemImage: "xmark.octagon.fill")
                            .font(.caption)
                            .foregroundStyle(theme.colorTokens.error.color)
                    }
                }
            }
        }
        .navigationTitle("从备份恢复")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("完成") { dismiss() }
            }
        }
        .fileImporter(
            isPresented: $isFilePickerPresented,
            allowedContentTypes: [.data],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case let .success(urls):
                guard let url = urls.first else { return }
                importFileURL = url
                importPassword = ""
                restoreError = nil
                restoreMessage = nil
            case let .failure(error):
                restoreError = "无法读取备份文件：\(error.localizedDescription)"
            }
        }
    }

    private func restoreBackup() async {
        guard let url = importFileURL else { return }
        isRestoring = true
        restoreError = nil
        restoreMessage = nil
        defer { isRestoring = false }
        do {
            let accessing = url.startAccessingSecurityScopedResource()
            defer {
                if accessing { url.stopAccessingSecurityScopedResource() }
            }
            let data = try Data(contentsOf: url)
            let backup = try service.decrypt(data, password: importPassword)
            await SettingsBackupSection.applyBackup(backup, model: model, themeStore: themeStore, vault: credentialVault)
            restoreMessage = "恢复完成。服务器不会自动同步，请在「服务器」中手动连接。"
        } catch {
            restoreError = error.localizedDescription
        }
    }
}
#endif
