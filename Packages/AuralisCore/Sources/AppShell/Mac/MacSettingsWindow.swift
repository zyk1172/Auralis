#if os(macOS)
import DesignSystem
import Domain
import LocalCatalog
import SecurityKit
import SwiftUI
import ThemeEngine

/// macOS 独立设置窗口（Settings Scene）。顶部分类工具栏，内容按分类拆分，不使用 iOS 长列表。
public struct MacSettingsWindow: View {
    public init(model: AuralisAppModel, themeStore: ThemeStore, settingsRouter: MacSettingsRouter) {
        self.model = model
        self.themeStore = themeStore
        self.settingsRouter = settingsRouter
    }
    @ObservedObject var model: AuralisAppModel
    @ObservedObject var themeStore: ThemeStore
    @ObservedObject var settingsRouter: MacSettingsRouter

    private var theme: BuiltInTheme { themeStore.current }

    public var body: some View {
        TabView(selection: $settingsRouter.selection) {
            general.tabItem { Label(MacSettingsCategory.general.title, systemImage: MacSettingsCategory.general.symbol) }.tag(MacSettingsCategory.general)
            server.tabItem { Label(MacSettingsCategory.server.title, systemImage: MacSettingsCategory.server.symbol) }.tag(MacSettingsCategory.server)
            libraryPlayback.tabItem { Label(MacSettingsCategory.libraryPlayback.title, systemImage: MacSettingsCategory.libraryPlayback.symbol) }.tag(MacSettingsCategory.libraryPlayback)
            ai.tabItem { Label(MacSettingsCategory.ai.title, systemImage: MacSettingsCategory.ai.symbol) }.tag(MacSettingsCategory.ai)
            system.tabItem { Label(MacSettingsCategory.system.title, systemImage: MacSettingsCategory.system.symbol) }.tag(MacSettingsCategory.system)
            about.tabItem { Label(MacSettingsCategory.about.title, systemImage: MacSettingsCategory.about.symbol) }.tag(MacSettingsCategory.about)
        }
        // 允许放大：大字体 / 长内容（AI、服务器）时可拉高窗口，避免固定尺寸裁剪。
        .frame(minWidth: 760, minHeight: 560)
        .padding(0)
        // Settings 是独立 Scene，必须显式继承 ThemeStore 的当前色板，不能落回系统默认蓝色。
        .tint(theme.colorTokens.accent.color)
        .preferredColorScheme(theme.colorScheme)
        .background(theme.colorTokens.background.color)
    }

    // MARK: - 通用

    private var general: some View {
        Form {
            Section("主题") {
                ThemeChoiceGrid(themeStore: themeStore)
                Text("已合并视觉结构重复的主题；旧主题选择会自动迁移到最接近的新主题。")
                    .font(.caption)
                    .foregroundStyle(theme.colorTokens.secondaryText.color)
            }
            Section("当前主题色板") {
                ThemeSwatchGrid(colors: theme.colorTokens, name: theme.name)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - 服务器

    private var server: some View {
        MacServerPage(model: model, theme: theme)
    }

    // MARK: - 资料库与播放

    @AppStorage("auralis.audio.highQualityWiFi") private var highQualityWiFi = true

    private var libraryPlayback: some View {
        Form {
            Section("资料库统计") {
                LabeledContent("歌曲", value: "\(model.catalog.tracks.count) 首")
                LabeledContent("专辑", value: "\(model.catalog.albums.count) 张")
                LabeledContent("艺术家", value: "\(model.catalog.artists.count) 位")
                LabeledContent("歌单", value: "\(model.catalog.playlists.count) 个")
            }
            CatalogSyncSection(model: model, theme: theme)
            Section("网络音质") {
                Toggle("Wi-Fi 优先原始音质", isOn: $highQualityWiFi)
                Text("开启后 Wi-Fi / 有线网络下优先使用服务器原始质量；关闭则限制码率（MP3 320kbps）以节省带宽。")
                    .font(.caption)
                    .foregroundStyle(theme.colorTokens.secondaryText.color)
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
                    .foregroundStyle(theme.colorTokens.secondaryText.color)
                Toggle("峰值保护", isOn: Binding(
                    get: { model.replayGainSettings.peakProtection },
                    set: { model.setReplayGainPeakProtection($0) }
                ))
                Text("默认关闭 ReplayGain。启用后优先使用服务器返回的真实 Track/Album Gain；缺少标签时不做普通音量归一化。")
                    .font(.caption)
                    .foregroundStyle(theme.colorTokens.secondaryText.color)
            }
            Section("离线下载") {
                LabeledContent("已离线", value: "\(model.catalog.downloads.count) 首")
                Text("用户主动下载的离线音乐与临时播放缓存分开存储；清理临时缓存不会删除已下载的音乐。")
                    .font(.caption)
                    .foregroundStyle(theme.colorTokens.secondaryText.color)
            }
            CacheManagementSection(model: model, theme: theme)
        }
        .formStyle(.grouped)
    }

    // MARK: - AI 助手

    @AppStorage("auralis.ai.enabled") private var aiEnabled = true
    @AppStorage("auralis.ai.allowsMetadata") private var allowsMetadata = true
    @AppStorage("auralis.ai.allowsLyrics") private var allowsLyrics = false
    @AppStorage("auralis.ai.allowsHistory") private var allowsHistory = false
    @AppStorage(AIConnectionSettings.Keys.baseURL) private var aiBaseURL = AIConnectionSettings.defaultBaseURL
    @AppStorage(AIConnectionSettings.Keys.apiPath) private var aiAPIPath = AIConnectionSettings.defaultAPIPath
    @AppStorage(AIConnectionSettings.Keys.model) private var aiModel = AIConnectionSettings.defaultModel
    @AppStorage(AIConnectionSettings.Keys.maxContextTokens) private var aiMaxContextTokens = AIConnectionSettings.defaultMaxContextTokens
    @AppStorage(AIConnectionSettings.Keys.maxOutputTokens) private var aiMaxOutputTokens = AIConnectionSettings.defaultMaxOutputTokens
    @AppStorage(ExternalMusicPreferences.Keys.enabled) private var externalMusicEnabled = true
    @AppStorage(ExternalMusicPreferences.Keys.musicBrainz) private var musicBrainzEnabled = true
    @AppStorage(ExternalMusicPreferences.Keys.critiqueBrainz) private var critiqueBrainzEnabled = true
    @AppStorage(ExternalMusicPreferences.Keys.listenBrainz) private var listenBrainzEnabled = true
    @State private var hasAPIKey = false
    @State private var indexStatus: RecommendationIndexV2Status?
    @State private var isLoadingIndexStatus = false
    @State private var isClearingExternalMusicCache = false
    @State private var isResettingExternalIdentity = false
    @State private var externalMusicMessage: String?
    @State private var isExportingIndex = false
    @State private var indexExportFile: RecommendationIndexV2IndexFile?
    @State private var isImportingIndex = false
    @State private var isPerformingIndexTransfer = false
    @State private var indexTransferMessage: String?
    @State private var isConfirmingIndexClear = false
    @State private var isClearingIndex = false

    private let credentialVault = KeychainCredentialVault()

    private var ai: some View {
        Form {
            Section("AI 与隐私") {
                Toggle("启用 AI 功能", isOn: $aiEnabled)
                Toggle("允许发送歌曲元数据", isOn: $allowsMetadata)
                Toggle("允许发送歌词", isOn: $allowsLyrics)
                Toggle("允许发送播放历史摘要", isOn: $allowsHistory)
            }
            Section("OpenAI 兼容接口") {
                TextField("Base URL", text: $aiBaseURL)
                TextField("API 路径", text: $aiAPIPath)
                TextField("模型", text: $aiModel)
                LabeledContent("API Key", value: hasAPIKey ? "已配置 · 存于系统 Keychain" : "未配置")
            }
            Section("高级设置") {
                Stepper(value: $aiMaxContextTokens, in: 4_096...1_000_000, step: 4_096) {
                    HStack {
                        Text("上下文窗口")
                        Spacer()
                        Text("\(aiMaxContextTokens) token").foregroundStyle(theme.colorTokens.secondaryText.color)
                    }
                }
                Stepper(value: $aiMaxOutputTokens, in: 512...64_000, step: 512) {
                    HStack {
                        Text("单次输出上限")
                        Spacer()
                        Text("\(aiMaxOutputTokens) token").foregroundStyle(theme.colorTokens.secondaryText.color)
                    }
                }
                Text("不同 OpenAI 兼容端点上下文窗口不同（OpenAI 128K/200K、DeepSeek 64K/128K、Ollama/LM Studio 取决于模型）。默认 256K / 16K 维持旧行为，可按实际模型修改。")
                    .font(.caption)
                    .foregroundStyle(theme.colorTokens.secondaryText.color)
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
                HStack {
                    Button {
                        Task { await clearExternalMusicCache() }
                    } label: {
                        if isClearingExternalMusicCache {
                            HStack { ProgressView().controlSize(.small); Text("正在清除…") }
                        } else {
                            Label("清除公开音乐数据缓存", systemImage: "trash")
                        }
                    }
                    .disabled(isClearingExternalMusicCache)
                    Button("重置音乐身份匹配…", role: .destructive) {
                        Task { await resetExternalMusicIdentity() }
                    }
                    .disabled(isResettingExternalIdentity)
                }
                if let externalMusicMessage {
                    Text(externalMusicMessage)
                        .font(.caption)
                        .foregroundStyle(theme.colorTokens.secondaryText.color)
                }
            }
            Section("推荐索引 V2") {
                if isLoadingIndexStatus && indexStatus == nil {
                    HStack { ProgressView().controlSize(.small); Text("正在读取索引状态…") }
                } else if let status = indexStatus {
                    LabeledContent("已分类", value: "\(status.indexedTracks) / \(status.totalTracks) 首")
                    LabeledContent("待处理", value: "\(status.pendingTracks) 首")
                    ProgressView(value: Double(status.indexedTracks), total: Double(max(status.totalTracks, 1)))
                        .tint(theme.colorTokens.accent.color)
                    LabeledContent("规则版本", value: status.rulesVersion)
                    LabeledContent("索引格式", value: "V2 包 v\(LocalCatalogStore.recommendationIndexV2PackageFormatVersion)")
                    HStack {
                        Button(status.pendingTracks == 0 ? "检查并更新索引" : "开始/继续全量索引") {
                            model.startOrContinueRecommendationIndexV2()
                        }
                        .disabled(model.catalog.activeServerID == nil || model.agentCoordinator.isRunning)
                        Button("导出索引…") { Task { await exportIndex() } }
                            .disabled(model.catalog.activeServerID == nil || isPerformingIndexTransfer)
                        Button("导入索引…") { isImportingIndex = true }
                            .disabled(model.catalog.activeServerID == nil || isPerformingIndexTransfer)
                        Button(role: .destructive) { isConfirmingIndexClear = true } label: {
                            Label(isClearingIndex ? "正在清空索引…" : "清空索引…", systemImage: "trash")
                        }
                            .disabled(model.catalog.activeServerID == nil || model.agentCoordinator.isRunning || isClearingIndex || isPerformingIndexTransfer)
                        Button("刷新状态") { Task { await refreshIndexStatus() } }
                    }
                } else {
                    Text("连接并同步音乐库后，可查看索引进度。")
                        .font(.caption)
                        .foregroundStyle(theme.colorTokens.secondaryText.color)
                    Button("开始全量索引") {
                        model.startOrContinueRecommendationIndexV2()
                    }
                    .disabled(model.catalog.activeServerID == nil || model.agentCoordinator.isRunning)
                }
                if let indexTransferMessage {
                    Text(indexTransferMessage)
                        .font(.caption)
                        .foregroundStyle(theme.colorTokens.secondaryText.color)
                }
            }
            AgentMemoryManagementSection(model: model, theme: theme)
            MoviePilotSettingsSection()
        }
        .formStyle(.grouped)
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
        externalMusicMessage = nil
        defer { isClearingExternalMusicCache = false }
        do {
            try await model.agentCoordinator.clearExternalMusicDataCache()
            externalMusicMessage = "公开音乐数据缓存已清除（保留已核验的音乐身份）。"
        } catch {
            externalMusicMessage = "清除失败：\(error.localizedDescription)"
        }
    }

    private func resetExternalMusicIdentity() async {
        isResettingExternalIdentity = true
        externalMusicMessage = nil
        defer { isResettingExternalIdentity = false }
        do {
            try await model.agentCoordinator.resetExternalMusicIdentity()
            externalMusicMessage = "音乐身份匹配已重置；下次打开歌曲信息/鉴赏时将重新识别 MBID。"
        } catch {
            externalMusicMessage = "重置失败：\(error.localizedDescription)"
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

    // MARK: - 系统

    @AppStorage("auralis.debug.crashLogEnabled") private var crashLogEnabled = true

    private var system: some View {
        Form {
            Section("系统集成") {
                LabeledContent("Siri 媒体播放", value: "已启用（AppIntents）")
                LabeledContent("快捷指令", value: "已启用")
                LabeledContent("后台播放", value: "已启用")
            }
            Text("Siri 与快捷指令只使用本地资料库的名称与标识进行匹配，不会暴露服务器地址、账号或令牌。")
                .font(.caption)
                .foregroundStyle(theme.colorTokens.secondaryText.color)
            SettingsBackupSection(model: model, themeStore: themeStore, theme: theme)
            Section("调试") {
                Toggle("启用崩溃日志", isOn: $crashLogEnabled)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - 关于

    private var about: some View {
        Form {
            Section {
                LabeledContent("版本", value: AppVersionInfo.display)
                LabeledContent("构建", value: "原生 macOS")
                Text("澜音 · 私人音乐服务器播放器（OpenSubsonic / Navidrome）")
                    .font(.caption)
                    .foregroundStyle(theme.colorTokens.secondaryText.color)
            }
        }
        .formStyle(.grouped)
    }
}

#endif
