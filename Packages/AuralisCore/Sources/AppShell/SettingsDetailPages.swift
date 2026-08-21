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

    var body: some View {
        SettingsDetailForm(title: String(localized: "主题", bundle: .module), theme: theme) {
            Section(String(localized: "主题外观", bundle: .module)) {
                ThemeChoiceGrid(themeStore: themeStore)
                Text(String(localized: "已合并视觉结构重复的主题；旧主题选择会自动迁移到最接近的新主题。", bundle: .module))
                    .font(.caption)
                    .foregroundStyle(theme.colorTokens.secondaryText.color)
            }
            Section(String(localized: "当前主题色板", bundle: .module)) {
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
        SettingsDetailForm(title: String(localized: "播放与音质", bundle: .module), theme: theme) {
            Section(String(localized: "网络音质", bundle: .module)) {
                Toggle(String(localized: "Wi-Fi 优先原始音质", bundle: .module), isOn: $highQualityWiFi)
                Toggle(String(localized: "蜂窝网络允许转码", bundle: .module), isOn: $cellularTranscoding)
            }
            Section(String(localized: "ReplayGain", bundle: .module)) {
                Picker(String(localized: "模式", bundle: .module), selection: Binding(
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
                    Text(String(localized: "前级", bundle: .module))
                } minimumValueLabel: {
                    Text("-12")
                } maximumValueLabel: {
                    Text("+12")
                }
                Text(String(localized: "前级：\(model.replayGainSettings.preampDB, specifier: "%+.1f") dB", bundle: .module))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle(String(localized: "峰值保护", bundle: .module), isOn: Binding(
                    get: { model.replayGainSettings.peakProtection },
                    set: { model.setReplayGainPeakProtection($0) }
                ))
                Text(String(localized: "默认关闭 ReplayGain。启用后优先使用服务器返回的真实 Track/Album Gain；缺少标签时不做普通音量归一化。", bundle: .module))
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
        SettingsDetailForm(title: String(localized: "数据与备份", bundle: .module), theme: theme) {
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
    @AppStorage(AIConnectionSettings.Keys.apiPath) private var aiAPIPath = AIConnectionSettings.defaultAPIPath
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
            Section(String(localized: "大模型", bundle: .module)) {
                LabeledContent(String(localized: "接口协议", bundle: .module), value: AIEndpointMode.infer(from: aiAPIPath).title)
                LabeledContent(String(localized: "Base URL", bundle: .module), value: aiBaseURL)
                LabeledContent(String(localized: "模型", bundle: .module), value: aiModel)
                LabeledContent(
                    "API Key",
                    value: hasAPIKey
                        ? String(localized: "已配置", bundle: .module)
                        : String(localized: "未配置", bundle: .module)
                )
                NavigationLink(String(localized: "配置大模型…", bundle: .module)) {
                    AIProviderSettingsPage(theme: theme, hasAPIKey: $hasAPIKey)
                }
            }
            Section(String(localized: "推荐索引 V2", bundle: .module)) {
                if isLoadingIndexStatus && indexStatus == nil {
                    HStack { ProgressView(); Text(String(localized: "正在读取索引状态…", bundle: .module)) }
                } else if let status = indexStatus {
                    LabeledContent(String(localized: "已分类", bundle: .module), value: String(localized: "\(status.indexedTracks) / \(status.totalTracks) 首", bundle: .module))
                    LabeledContent(String(localized: "待处理", bundle: .module), value: String(localized: "\(status.pendingTracks) 首", bundle: .module))
                    ProgressView(value: Double(status.indexedTracks), total: Double(max(status.totalTracks, 1)))
                        .tint(theme.colorTokens.accent.color)
                    LabeledContent(String(localized: "规则版本", bundle: .module), value: status.rulesVersion)
                    LabeledContent(String(localized: "索引格式", bundle: .module), value: String(localized: "V2 包 v\(LocalCatalogStore.recommendationIndexV2PackageFormatVersion)", bundle: .module))
                    Button {
                        model.startOrContinueRecommendationIndexV2()
                    } label: {
                        Label(
                            status.pendingTracks == 0
                                ? String(localized: "检查并更新索引", bundle: .module)
                                : String(localized: "开始/继续全量索引", bundle: .module),
                            systemImage: "sparkles.rectangle.stack"
                        )
                    }
                    .disabled(model.catalog.activeServerID == nil || model.agentCoordinator.isRunning)
                    HStack {
                        Button(String(localized: "导出索引…", bundle: .module)) { Task { await exportIndex() } }
                            .disabled(model.catalog.activeServerID == nil || isPerformingIndexTransfer)
                        Button(String(localized: "导入索引…", bundle: .module)) { isImportingIndex = true }
                            .disabled(model.catalog.activeServerID == nil || isPerformingIndexTransfer)
                    }
                    Button(role: .destructive) { isConfirmingIndexClear = true } label: {
                        if isClearingIndex {
                            Label(String(localized: "正在清空索引…", bundle: .module), systemImage: "trash")
                        } else {
                            Label(String(localized: "清空索引…", bundle: .module), systemImage: "trash")
                        }
                    }
                        .disabled(model.catalog.activeServerID == nil || model.agentCoordinator.isRunning || isClearingIndex || isPerformingIndexTransfer)
                    if let indexTransferMessage {
                        Text(indexTransferMessage)
                            .font(.caption)
                            .foregroundStyle(theme.colorTokens.secondaryText.color)
                    }
                    Button(String(localized: "刷新状态", bundle: .module)) { Task { await refreshIndexStatus() } }
                } else {
                    Text(String(localized: "连接并同步音乐库后，可查看索引进度。", bundle: .module))
                        .font(.caption)
                        .foregroundStyle(theme.colorTokens.secondaryText.color)
                    Button {
                        model.startOrContinueRecommendationIndexV2()
                    } label: {
                        Label(String(localized: "开始全量索引", bundle: .module), systemImage: "sparkles.rectangle.stack")
                    }
                    .disabled(model.catalog.activeServerID == nil || model.agentCoordinator.isRunning)
                }
            }
            Section(String(localized: "助手偏好", bundle: .module)) {
                Picker(String(localized: "推荐场景", bundle: .module), selection: sceneBinding) {
                    Text(String(localized: "无偏好", bundle: .module)).tag("")
                    Text(String(localized: "深夜", bundle: .module)).tag(String(localized: "深夜", bundle: .module))
                    Text(String(localized: "通勤", bundle: .module)).tag(String(localized: "通勤", bundle: .module))
                    Text(String(localized: "学习", bundle: .module)).tag(String(localized: "学习", bundle: .module))
                    Text(String(localized: "运动", bundle: .module)).tag(String(localized: "运动", bundle: .module))
                }
                Picker(String(localized: "重复容忍度", bundle: .module), selection: repeatBinding) {
                    Text(String(localized: "允许少量重复", bundle: .module)).tag("allow")
                    Text(String(localized: "尽量不重复", bundle: .module)).tag("avoid")
                }
            }
            Section(String(localized: "AI 与隐私", bundle: .module)) {
                Toggle(String(localized: "启用 AI 功能", bundle: .module), isOn: $aiEnabled)
                Toggle(String(localized: "允许发送歌曲元数据", bundle: .module), isOn: $allowsMetadata)
                Toggle(String(localized: "允许发送歌词", bundle: .module), isOn: $allowsLyrics)
                Toggle(String(localized: "允许发送播放历史摘要", bundle: .module), isOn: $allowsHistory)
            }
            Section(String(localized: "公开音乐数据", bundle: .module)) {
                Toggle(String(localized: "启用公开音乐数据", bundle: .module), isOn: $externalMusicEnabled)
                Toggle(String(localized: "MusicBrainz", bundle: .module), isOn: $musicBrainzEnabled)
                    .disabled(!externalMusicEnabled)
                Toggle(String(localized: "CritiqueBrainz", bundle: .module), isOn: $critiqueBrainzEnabled)
                    .disabled(!externalMusicEnabled)
                Toggle(String(localized: "ListenBrainz", bundle: .module), isOn: $listenBrainzEnabled)
                    .disabled(!externalMusicEnabled)
                Text(String(localized: "仅在打开歌曲信息、歌曲鉴赏等需要公开音乐资料的功能时按需查询。不会上传音频文件、歌词、播放地址、NAS 密码或完整音乐库。查询结果默认缓存 14 天。", bundle: .module))
                    .font(.caption)
                    .foregroundStyle(theme.colorTokens.secondaryText.color)
                Button {
                    Task { await clearExternalMusicCache() }
                } label: {
                    if isClearingExternalMusicCache {
                        HStack { ProgressView(); Text(String(localized: "正在清除…", bundle: .module)) }
                    } else {
                        Label(String(localized: "清除公开音乐数据缓存", bundle: .module), systemImage: "trash")
                    }
                }
                .disabled(isClearingExternalMusicCache)
                Button(String(localized: "重置音乐身份匹配…", bundle: .module), role: .destructive) {
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
                indexTransferMessage = String(localized: "导出失败：\(error.localizedDescription)", bundle: .module)
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
                indexTransferMessage = String(localized: "导入失败：\(error.localizedDescription)", bundle: .module)
            }
        }
        .task {
            hasAPIKey = (try? await credentialVault.retrieve(id: AIConnectionSettings.credentialID)) != nil
            await refreshIndexStatus()
        }
        .task(id: model.catalog.activeServerID) { await refreshIndexStatus() }
        .confirmationDialog(String(localized: "清空本机推荐索引 V2？", bundle: .module), isPresented: $isConfirmingIndexClear, titleVisibility: .visible) {
            Button(String(localized: "清空索引", bundle: .module), role: .destructive) {
                Task { await clearRecommendationIndex() }
            }
            Button(String(localized: "取消", bundle: .module), role: .cancel) {}
        } message: {
            Text(String(localized: "将删除当前服务器的所有 V2 分类与 AI 标签。音乐库、下载、播放记录和其他服务器的索引不会受影响；之后可重新开始索引。", bundle: .module))
        }
    }

    private var defaultIndexExportFilename: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return String(localized: "Auralis-推荐索引-V2-\(formatter.string(from: Date()))", bundle: .module)
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
            indexTransferMessage = String(localized: "当前服务器的推荐索引 V2 已清空，可重新开始索引。", bundle: .module)
            await refreshIndexStatus()
        } catch {
            indexTransferMessage = String(localized: "清空索引失败：\(error.localizedDescription)", bundle: .module)
        }
    }

    private func clearExternalMusicCache() async {
        isClearingExternalMusicCache = true
        externalMusicCacheMessage = nil
        defer { isClearingExternalMusicCache = false }
        do {
            try await model.agentCoordinator.clearExternalMusicDataCache()
            externalMusicCacheMessage = String(localized: "公开音乐数据缓存已清除（保留已核验的音乐身份）。", bundle: .module)
        } catch {
            externalMusicCacheMessage = String(localized: "清除失败：\(error.localizedDescription)", bundle: .module)
        }
    }

    private func resetExternalMusicIdentity() async {
        isResettingExternalIdentity = true
        externalMusicCacheMessage = nil
        defer { isResettingExternalIdentity = false }
        do {
            try await model.agentCoordinator.resetExternalMusicIdentity()
            externalMusicCacheMessage = String(localized: "音乐身份匹配已重置；下次打开歌曲信息/鉴赏时将重新识别 MBID。", bundle: .module)
        } catch {
            externalMusicCacheMessage = String(localized: "重置失败：\(error.localizedDescription)", bundle: .module)
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
            indexTransferMessage = String(localized: "导出失败：\(error.localizedDescription)", bundle: .module)
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
            indexTransferMessage = String(localized: "成功导入 \(stats.imported) 首；已存在 \(stats.alreadyExists) 首；歌曲已变化 \(stats.metadataChanged) 首；当前音乐库不存在 \(stats.notFound) 首；格式错误 \(stats.malformed) 首。", bundle: .module)
            await refreshIndexStatus()
        } catch {
            indexTransferMessage = String(localized: "导入失败：\(error.localizedDescription)", bundle: .module)
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
        SettingsDetailForm(title: String(localized: "服务器", bundle: .module), theme: theme) {
            Section(String(localized: "当前服务器", bundle: .module)) {
                if model.catalogFallbackUsed {
                    Label {
                        Text(String(localized: "本地目录库打不开，当前运行在临时降级目录上：同步与搜索只对本次会话有效，请检查磁盘空间或应用支持目录。", bundle: .module))
                            .font(.caption)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(theme.colorTokens.error.color)
                    }
                    .foregroundStyle(theme.colorTokens.secondaryText.color)
                }
                serverSummary
                if case .connected = model.serverConnectionState {
                    Button(String(localized: "测试连接", bundle: .module)) { Task { pingResult = await model.testActiveServerConnection() } }
                    if let pingResult {
                        Label(
                pingResult ? String(localized: "服务器可达", bundle: .module) : String(localized: "服务器无响应", bundle: .module),
                            systemImage: pingResult ? "checkmark.circle.fill" : "xmark.octagon.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(pingResult ? theme.colorTokens.success.color : theme.colorTokens.error.color)
                    }
                    Button(String(localized: "移除当前服务器（仅本机）", bundle: .module), role: .destructive) { isRemovingServer = true }
                }
            }
            Section(String(localized: "已保存的服务器", bundle: .module)) {
                ForEach(savedServers) { server in serverRow(server) }
                Button(String(localized: "添加 OpenSubsonic 服务器", bundle: .module)) { isAddingServer = true }
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
            serverToSwitch.map { String(localized: "切换到「\($0.displayName)」？", bundle: .module) } ?? String(localized: "切换服务器？", bundle: .module),
            isPresented: Binding(get: { serverToSwitch != nil }, set: { if !$0 { serverToSwitch = nil } }),
            titleVisibility: .visible
        ) {
            Button(String(localized: "切换", bundle: .module)) {
                guard let server = serverToSwitch else { return }
                serverToSwitch = nil
                Task {
                    await model.switchServer(serverID: server.id)
                    await reloadServers()
                }
            }
            Button(String(localized: "取消", bundle: .module), role: .cancel) { serverToSwitch = nil }
        } message: {
            Text(String(localized: "切换只影响本机资料库和播放会话，不会修改服务器数据。", bundle: .module))
        }
        .alert(String(localized: "移除服务器？", bundle: .module), isPresented: $isRemovingServer) {
            Button(String(localized: "移除", bundle: .module), role: .destructive) {
                guard let serverID = model.catalog.activeServerID else { return }
                Task {
                    await model.catalogCoordinator.purgeLocalData(serverID: serverID)
                    await model.removeServerLocally(serverID: serverID)
                    await reloadServers()
                }
            }
            Button(String(localized: "取消", bundle: .module), role: .cancel) {}
        } message: {
            Text(String(localized: "仅删除本机登录凭据、目录与缓存；服务器上的音乐、歌单和收藏不会被删除。", bundle: .module))
        }
    }

    @ViewBuilder
    private var serverSummary: some View {
        switch model.serverConnectionState {
        case .idle:
            LabeledContent(String(localized: "状态", bundle: .module), value: String(localized: "未连接", bundle: .module))
        case let .connecting(stage):
            HStack { ProgressView(); Text(stage.title) }
        case let .connected(account, _, _, trackCount):
            LabeledContent(String(localized: "资料库", bundle: .module), value: account.displayName)
            LabeledContent(String(localized: "已同步", bundle: .module), value: String(localized: "\(trackCount) 首歌曲", bundle: .module))
        case let .failed(message):
            Label(String(localized: "连接失败", bundle: .module), systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(theme.colorTokens.error.color)
            Text(message).font(.caption).foregroundStyle(theme.colorTokens.secondaryText.color)
            Button(String(localized: "重新连接", bundle: .module)) { isAddingServer = true }
        }
    }

    @ViewBuilder
    private func serverRow(_ server: ServerAccount) -> some View {
        let active = model.catalog.activeServerID == server.id
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(server.displayName)
                Text(active ? String(localized: "当前使用", bundle: .module) : (server.baseURL?.host ?? String(localized: "未设地址", bundle: .module)))
                    .font(.caption)
                    .foregroundStyle(active ? theme.colorTokens.success.color : theme.colorTokens.secondaryText.color)
            }
            Spacer()
            Menu {
                Button(String(localized: "编辑服务器", bundle: .module)) { serverToEdit = server }
                if !active { Button(String(localized: "切换到此服务器", bundle: .module)) { serverToSwitch = server } }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    private func reloadServers() async {
        savedServers = (try? await model.catalogCoordinator.store.listServers()) ?? []
    }
}
