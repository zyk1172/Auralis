import Application
import DesignSystem
import Domain
import LocalCatalog
import SecurityKit
import SwiftUI
import ThemeEngine

/// 设置首页的分类入口。首页只显示去向和必要状态，具体配置留在二级页面。
struct SettingsCategoryRow: View {
    let title: String
    let subtitle: String
    let icon: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } icon: {
            Image(systemName: icon)
                .symbolRenderingMode(.hierarchical)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

private struct SettingsDetailForm<Content: View>: View {
    let title: String
    let theme: BuiltInTheme
    @ViewBuilder let content: Content
    @Environment(\.bottomDockReservedHeight) private var bottomDockReservedHeight

    var body: some View {
        Form { content }
            .navigationTitle(title)
            .scrollContentBackground(.hidden)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Color.clear.frame(height: bottomDockReservedHeight)
            }
            .background(theme.colorTokens.background.color)
    }
}

struct ThemeSettingsPage: View {
    @ObservedObject var themeStore: ThemeStore

    private var theme: BuiltInTheme { themeStore.current }
    private var selection: Binding<String> {
        Binding(get: { themeStore.selectedID }, set: { themeStore.select(id: $0) })
    }

    var body: some View {
        SettingsDetailForm(title: "主题", theme: theme) {
            Section("主题外观") {
                Picker("主题", selection: selection) {
                    ForEach(themeStore.themes) { candidate in
                        Text(candidate.name).tag(candidate.id)
                    }
                }
                .pickerStyle(.menu)
                ThemeSwatchGrid(colors: theme.colorTokens, name: theme.name)
            }
        }
    }
}

struct PlaybackSettingsPage: View {
    @ObservedObject var model: AuralisAppModel
    let theme: BuiltInTheme
    @AppStorage("auralis.audio.highQualityWiFi") private var highQualityWiFi = true
    @AppStorage("auralis.audio.cellularTranscoding") private var cellularTranscoding = true

    var body: some View {
        SettingsDetailForm(title: "播放与音质", theme: theme) {
            Section("网络音质") {
                Toggle("Wi-Fi 优先原始音质", isOn: $highQualityWiFi)
                Toggle("蜂窝网络允许转码", isOn: $cellularTranscoding)
            }
            Section("ReplayGain") {
                Picker("模式", selection: Binding(
                    get: { model.replayGainSettings.mode },
                    set: { model.setReplayGainMode($0) }
                )) {
                    ForEach(ReplayGainMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                Slider(
                    value: Binding(
                        get: { model.replayGainSettings.preampDB },
                        set: { model.setReplayGainPreamp($0) }
                    ),
                    in: -12...12,
                    step: 0.5
                ) {
                    Text("前级")
                } minimumValueLabel: {
                    Text("-12")
                } maximumValueLabel: {
                    Text("+12")
                }
                Text("前级：\(model.replayGainSettings.preampDB, specifier: "%+.1f") dB")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("峰值保护", isOn: Binding(
                    get: { model.replayGainSettings.peakProtection },
                    set: { model.setReplayGainPeakProtection($0) }
                ))
                Text("默认关闭 ReplayGain。启用后优先使用服务器返回的真实 Track/Album Gain；缺少标签时不做普通音量归一化。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct DataSettingsPage: View {
    @ObservedObject var model: AuralisAppModel
    @ObservedObject var themeStore: ThemeStore
    let theme: BuiltInTheme

    var body: some View {
        SettingsDetailForm(title: "数据与备份", theme: theme) {
            CacheManagementSection(model: model, theme: theme)
            SettingsBackupSection(
                model: model,
                themeStore: themeStore,
                theme: theme
            )
        }
    }
}

struct AgentSettingsPage: View {
    @ObservedObject var model: AuralisAppModel
    let theme: BuiltInTheme
    @AppStorage("auralis.ai.enabled") private var aiEnabled = true
    @AppStorage("auralis.ai.allowsMetadata") private var allowsMetadata = true
    @AppStorage("auralis.ai.allowsLyrics") private var allowsLyrics = false
    @AppStorage("auralis.ai.allowsHistory") private var allowsHistory = false
    @AppStorage(ExternalMusicPreferences.Keys.enabled) private var externalMusicEnabled = true
    @AppStorage(ExternalMusicPreferences.Keys.musicBrainz) private var musicBrainzEnabled = true
    @AppStorage(ExternalMusicPreferences.Keys.critiqueBrainz) private var critiqueBrainzEnabled = true
    @AppStorage(ExternalMusicPreferences.Keys.listenBrainz) private var listenBrainzEnabled = true
    @AppStorage(AIConnectionSettings.Keys.baseURL) private var aiBaseURL = AIConnectionSettings.defaultBaseURL
    @AppStorage(AIConnectionSettings.Keys.model) private var aiModel = AIConnectionSettings.defaultModel
    @State private var hasAPIKey = false
    @State private var indexStatus: RecommendationIndexV2Status?
    @State private var isLoadingIndexStatus = false
    @State private var isClearingExternalMusicCache = false
    @State private var externalMusicCacheMessage: String?
    @State private var isResettingExternalIdentity = false
    @State private var isExportingIndex = false
    @State private var indexExportFile: RecommendationIndexV2IndexFile?
    @State private var isImportingIndex = false
    @State private var indexTransferMessage: String?
    @State private var isPerformingIndexTransfer = false
    @State private var isConfirmingIndexClear = false
    @State private var isClearingIndex = false

    private let credentialVault = KeychainCredentialVault()

    var body: some View {
        SettingsDetailForm(title: "Agent", theme: theme) {
            Section("大模型") {
                LabeledContent("接口", value: aiBaseURL)
                LabeledContent("模型", value: aiModel)
                LabeledContent("API Key", value: hasAPIKey ? "已配置" : "未配置")
                NavigationLink("配置大模型…") {
                    AIProviderSettingsPage(theme: theme, hasAPIKey: $hasAPIKey)
                }
            }
            Section("推荐索引 V2") {
                if isLoadingIndexStatus && indexStatus == nil {
                    HStack { ProgressView(); Text("正在读取索引状态…") }
                } else if let status = indexStatus {
                    LabeledContent("已分类", value: "\(status.indexedTracks) / \(status.totalTracks) 首")
                    LabeledContent("待处理", value: "\(status.pendingTracks) 首")
                    ProgressView(value: Double(status.indexedTracks), total: Double(max(status.totalTracks, 1)))
                        .tint(theme.colorTokens.accent.color)
                    LabeledContent("规则版本", value: status.rulesVersion)
                    LabeledContent("索引格式", value: "V2 包 v\(LocalCatalogStore.recommendationIndexV2PackageFormatVersion)")
                    Button {
                        model.startOrContinueRecommendationIndexV2()
                    } label: {
                        Label(
                            status.pendingTracks == 0 ? "检查并更新索引" : "开始/继续全量索引",
                            systemImage: "sparkles.rectangle.stack"
                        )
                    }
                    .disabled(model.catalog.activeServerID == nil || model.agentCoordinator.isRunning)
                    HStack {
                        Button("导出索引…") { Task { await exportIndex() } }
                            .disabled(model.catalog.activeServerID == nil || isPerformingIndexTransfer)
                        Button("导入索引…") { isImportingIndex = true }
                            .disabled(model.catalog.activeServerID == nil || isPerformingIndexTransfer)
                    }
                    Button(role: .destructive) { isConfirmingIndexClear = true } label: {
                        if isClearingIndex {
                            Label("正在清空索引…", systemImage: "trash")
                        } else {
                            Label("清空索引…", systemImage: "trash")
                        }
                    }
                        .disabled(model.catalog.activeServerID == nil || model.agentCoordinator.isRunning || isClearingIndex || isPerformingIndexTransfer)
                    if let indexTransferMessage {
                        Text(indexTransferMessage)
                            .font(.caption)
                            .foregroundStyle(theme.colorTokens.secondaryText.color)
                    }
                    Button("刷新状态") { Task { await refreshIndexStatus() } }
                } else {
                    Text("连接并同步音乐库后，可查看索引进度。")
                        .font(.caption)
                        .foregroundStyle(theme.colorTokens.secondaryText.color)
                    Button {
                        model.startOrContinueRecommendationIndexV2()
                    } label: {
                        Label("开始全量索引", systemImage: "sparkles.rectangle.stack")
                    }
                    .disabled(model.catalog.activeServerID == nil || model.agentCoordinator.isRunning)
                }
            }
            Section("助手偏好") {
                Picker("推荐场景", selection: sceneBinding) {
                    Text("无偏好").tag("")
                    Text("深夜").tag("深夜")
                    Text("通勤").tag("通勤")
                    Text("学习").tag("学习")
                    Text("运动").tag("运动")
                }
                Picker("重复容忍度", selection: repeatBinding) {
                    Text("允许少量重复").tag("allow")
                    Text("尽量不重复").tag("avoid")
                }
            }
            Section("AI 与隐私") {
                Toggle("启用 AI 功能", isOn: $aiEnabled)
                Toggle("允许发送歌曲元数据", isOn: $allowsMetadata)
                Toggle("允许发送歌词", isOn: $allowsLyrics)
                Toggle("允许发送播放历史摘要", isOn: $allowsHistory)
            }
            Section("公开音乐数据") {
                Toggle("启用公开音乐数据", isOn: $externalMusicEnabled)
                Toggle("MusicBrainz", isOn: $musicBrainzEnabled)
                    .disabled(!externalMusicEnabled)
                Toggle("CritiqueBrainz", isOn: $critiqueBrainzEnabled)
                    .disabled(!externalMusicEnabled)
                Toggle("ListenBrainz", isOn: $listenBrainzEnabled)
                    .disabled(!externalMusicEnabled)
                Text("仅在打开歌曲信息、歌曲鉴赏等需要公开音乐资料的功能时按需查询。不会上传音频文件、歌词、播放地址、NAS 密码或完整音乐库。查询结果默认缓存 14 天。")
                    .font(.caption)
                    .foregroundStyle(theme.colorTokens.secondaryText.color)
                Button {
                    Task { await clearExternalMusicCache() }
                } label: {
                    if isClearingExternalMusicCache {
                        HStack { ProgressView(); Text("正在清除…") }
                    } else {
                        Label("清除公开音乐数据缓存", systemImage: "trash")
                    }
                }
                .disabled(isClearingExternalMusicCache)
                Button("重置音乐身份匹配…", role: .destructive) {
                    Task { await resetExternalMusicIdentity() }
                }
                .disabled(isResettingExternalIdentity)
                if let externalMusicCacheMessage {
                    Text(externalMusicCacheMessage)
                        .font(.caption)
                        .foregroundStyle(theme.colorTokens.secondaryText.color)
                }
            }
            AgentMemoryManagementSection(model: model, theme: theme)
        }
        .fileExporter(
            isPresented: $isExportingIndex,
            document: indexExportFile,
            contentType: .auralisIndexV2,
            defaultFilename: defaultIndexExportFilename
        ) { result in
            if case let .failure(error) = result {
                indexTransferMessage = "导出失败：\(error.localizedDescription)"
            }
        }
        .fileImporter(
            isPresented: $isImportingIndex,
            allowedContentTypes: [.auralisIndexV2, .json, .data]
        ) { result in
            switch result {
            case let .success(url):
                Task { await importIndex(from: url) }
            case let .failure(error):
                indexTransferMessage = "导入失败：\(error.localizedDescription)"
            }
        }
        .task {
            hasAPIKey = (try? await credentialVault.retrieve(id: AIConnectionSettings.credentialID)) != nil
            await refreshIndexStatus()
        }
        .task(id: model.catalog.activeServerID) { await refreshIndexStatus() }
        .confirmationDialog("清空本机推荐索引 V2？", isPresented: $isConfirmingIndexClear, titleVisibility: .visible) {
            Button("清空索引", role: .destructive) {
                Task { await clearRecommendationIndex() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将删除当前服务器的所有 V2 分类与 AI 标签。音乐库、下载、播放记录和其他服务器的索引不会受影响；之后可重新开始索引。")
        }
    }

    private var defaultIndexExportFilename: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return "Auralis-推荐索引-V2-\(formatter.string(from: Date()))"
    }

    private var sceneBinding: Binding<String> {
        Binding(
            get: { UserDefaults.standard.string(forKey: "auralis.agent.scene") ?? "" },
            set: { UserDefaults.standard.set($0, forKey: "auralis.agent.scene") }
        )
    }

    private var repeatBinding: Binding<String> {
        Binding(
            get: { UserDefaults.standard.string(forKey: "auralis.agent.repeatTolerance") ?? "allow" },
            set: { UserDefaults.standard.set($0, forKey: "auralis.agent.repeatTolerance") }
        )
    }

    private func refreshIndexStatus() async {
        guard let serverID = model.catalog.activeServerID else {
            indexStatus = nil
            return
        }
        isLoadingIndexStatus = true
        indexStatus = try? await model.catalogCoordinator.store.recommendationIndexV2Status(serverID: serverID)
        isLoadingIndexStatus = false
    }

    private func clearRecommendationIndex() async {
        guard let serverID = model.catalog.activeServerID else { return }
        isClearingIndex = true
        indexTransferMessage = nil
        defer { isClearingIndex = false }
        do {
            try await model.catalogCoordinator.store.clearRecommendationIndexV2(serverID: serverID)
            guard model.catalog.activeServerID == serverID else { return }
            indexTransferMessage = "当前服务器的推荐索引 V2 已清空，可重新开始索引。"
            await refreshIndexStatus()
        } catch {
            indexTransferMessage = "清空索引失败：\(error.localizedDescription)"
        }
    }

    private func clearExternalMusicCache() async {
        isClearingExternalMusicCache = true
        externalMusicCacheMessage = nil
        defer { isClearingExternalMusicCache = false }
        do {
            try await model.agentCoordinator.clearExternalMusicDataCache()
            externalMusicCacheMessage = "公开音乐数据缓存已清除（保留已核验的音乐身份）。"
        } catch {
            externalMusicCacheMessage = "清除失败：\(error.localizedDescription)"
        }
    }

    private func resetExternalMusicIdentity() async {
        isResettingExternalIdentity = true
        externalMusicCacheMessage = nil
        defer { isResettingExternalIdentity = false }
        do {
            try await model.agentCoordinator.resetExternalMusicIdentity()
            externalMusicCacheMessage = "音乐身份匹配已重置；下次打开歌曲信息/鉴赏时将重新识别 MBID。"
        } catch {
            externalMusicCacheMessage = "重置失败：\(error.localizedDescription)"
        }
    }

    /// 导出当前服务器的 V2 索引为 `.auralis-index-v2` 包；只导出已完成且元数据
    /// 匹配当前内容指纹的歌曲，不包含任何凭据、播放地址或私人播放数据。
    private func exportIndex() async {
        guard let serverID = model.catalog.activeServerID else { return }
        isPerformingIndexTransfer = true
        indexTransferMessage = nil
        defer { isPerformingIndexTransfer = false }
        do {
            let package = try await model.catalogCoordinator.store.exportRecommendationIndexV2Package(serverID: serverID)
            let data = try JSONEncoder().encode(package)
            indexExportFile = RecommendationIndexV2IndexFile(data: data)
            isExportingIndex = true
        } catch {
            indexTransferMessage = "导出失败：\(error.localizedDescription)"
        }
    }

    /// 从用户选择的 `.auralis-index-v2` 文件导入到当前服务器；导入使用 SQLite
    /// 事务并逐条统计，一首失败不会让整个文件失败。
    private func importIndex(from url: URL) async {
        guard let serverID = model.catalog.activeServerID else { return }
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing { url.stopAccessingSecurityScopedResource() }
        }
        isPerformingIndexTransfer = true
        indexTransferMessage = nil
        defer { isPerformingIndexTransfer = false }
        do {
            let data = try Data(contentsOf: url)
            let stats = try await model.catalogCoordinator.store.importRecommendationIndexV2Package(
                data: data,
                serverID: serverID
            )
            indexTransferMessage = "成功导入 \(stats.imported) 首；已存在 \(stats.alreadyExists) 首；歌曲已变化 \(stats.metadataChanged) 首；当前音乐库不存在 \(stats.notFound) 首；格式错误 \(stats.malformed) 首。"
            await refreshIndexStatus()
        } catch {
            indexTransferMessage = "导入失败：\(error.localizedDescription)"
        }
    }
}

struct ServerSettingsPage: View {
    @ObservedObject var model: AuralisAppModel
    let theme: BuiltInTheme
    @State private var isAddingServer = false
    @State private var pingResult: Bool?
    @State private var isRemovingServer = false
    @State private var savedServers: [ServerAccount] = []
    @State private var serverToSwitch: ServerAccount?
    @State private var serverToEdit: ServerAccount?

    var body: some View {
        SettingsDetailForm(title: "服务器", theme: theme) {
            Section("当前服务器") {
                serverSummary
                if case .connected = model.serverConnectionState {
                    Button("测试连接") { Task { pingResult = await model.testActiveServerConnection() } }
                    if let pingResult {
                        Label(
                            pingResult ? "服务器可达" : "服务器无响应",
                            systemImage: pingResult ? "checkmark.circle.fill" : "xmark.octagon.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(pingResult ? theme.colorTokens.success.color : theme.colorTokens.error.color)
                    }
                    Button("移除当前服务器（仅本机）", role: .destructive) { isRemovingServer = true }
                }
            }
            Section("已保存的服务器") {
                ForEach(savedServers) { server in serverRow(server) }
                Button("添加 OpenSubsonic 服务器") { isAddingServer = true }
            }
            CatalogSyncSection(model: model, theme: theme)
            MoviePilotSettingsSection()
        }
        .task { await reloadServers() }
        .sheet(isPresented: $isAddingServer) {
            ServerConnectionSheet(model: model, theme: theme)
        }
        .sheet(item: $serverToEdit) { server in
            ServerEditSheet(model: model, theme: theme, server: server) { await reloadServers() }
        }
        .confirmationDialog(
            serverToSwitch.map { "切换到「\($0.displayName)」？" } ?? "切换服务器？",
            isPresented: Binding(get: { serverToSwitch != nil }, set: { if !$0 { serverToSwitch = nil } }),
            titleVisibility: .visible
        ) {
            Button("切换") {
                guard let server = serverToSwitch else { return }
                serverToSwitch = nil
                Task {
                    await model.switchServer(serverID: server.id)
                    await reloadServers()
                }
            }
            Button("取消", role: .cancel) { serverToSwitch = nil }
        } message: {
            Text("切换只影响本机资料库和播放会话，不会修改服务器数据。")
        }
        .alert("移除服务器？", isPresented: $isRemovingServer) {
            Button("移除", role: .destructive) {
                guard let serverID = model.catalog.activeServerID else { return }
                Task {
                    await model.catalogCoordinator.purgeLocalData(serverID: serverID)
                    await model.removeServerLocally(serverID: serverID)
                    await reloadServers()
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("仅删除本机登录凭据、目录与缓存；服务器上的音乐、歌单和收藏不会被删除。")
        }
    }

    @ViewBuilder
    private var serverSummary: some View {
        switch model.serverConnectionState {
        case .idle:
            LabeledContent("状态", value: "未连接")
        case let .connecting(stage):
            HStack { ProgressView(); Text(stage.title) }
        case let .connected(account, _, _, trackCount):
            LabeledContent("资料库", value: account.displayName)
            LabeledContent("已同步", value: "\(trackCount) 首歌曲")
        case let .failed(message):
            Label("连接失败", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(theme.colorTokens.error.color)
            Text(message).font(.caption).foregroundStyle(theme.colorTokens.secondaryText.color)
            Button("重新连接") { isAddingServer = true }
        }
    }

    @ViewBuilder
    private func serverRow(_ server: ServerAccount) -> some View {
        let active = model.catalog.activeServerID == server.id
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(server.displayName)
                Text(active ? "当前使用" : (server.baseURL?.host ?? "未设地址"))
                    .font(.caption)
                    .foregroundStyle(active ? theme.colorTokens.success.color : theme.colorTokens.secondaryText.color)
            }
            Spacer()
            Menu {
                Button("编辑服务器") { serverToEdit = server }
                if !active { Button("切换到此服务器") { serverToSwitch = server } }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    private func reloadServers() async {
        savedServers = (try? await model.catalogCoordinator.store.listServers()) ?? []
    }
}
