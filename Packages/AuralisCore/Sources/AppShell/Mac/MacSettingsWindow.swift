#if os(macOS)
import DesignSystem
import Domain
import LocalCatalog
import SecurityKit
import SwiftUI
import ThemeEngine
import UniformTypeIdentifiers

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

    @State private var isEditingHomeLayout = false

    private var general: some View {
        Form {
            Section(String(localized: "首页", bundle: .module)) {
                Button(String(localized: "编辑首页…", bundle: .module)) {
                    isEditingHomeLayout = true
                }
                .help(String(localized: "调整 Mac 首页内容模块的显示与顺序（随机音乐 / 最近播放 / 很久没听 / 最近添加 / 收藏里随便听 / 从未播放 / 常听艺术家 / 常听专辑）。", bundle: .module))
            }
            Section(String(localized: "主题", bundle: .module)) {
                ThemeChoiceGrid(themeStore: themeStore)
                Text(String(localized: "已合并视觉结构重复的主题；旧主题选择会自动迁移到最接近的新主题。", bundle: .module))
                    .font(.caption)
                    .foregroundStyle(theme.colorTokens.secondaryText.color)
            }
            Section(String(localized: "当前主题色板", bundle: .module)) {
                ThemeSwatchGrid(colors: theme.colorTokens, name: theme.name)
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $isEditingHomeLayout) {
            MacHomeLayoutEditor(model: model, theme: theme)
        }
    }

    // MARK: - 服务器

    private var server: some View {
        MacServerPage(model: model, theme: theme)
    }

    // MARK: - 资料库与播放

    @AppStorage("auralis.audio.highQualityWiFi") private var highQualityWiFi = true

    private var libraryPlayback: some View {
        Form {
            Section(String(localized: "资料库统计", bundle: .module)) {
                LabeledContent(String(localized: "歌曲", bundle: .module), value: L10n.songs(model.catalog.tracks.count))
                LabeledContent(String(localized: "专辑", bundle: .module), value: L10n.albums(model.catalog.albums.count))
                LabeledContent(String(localized: "艺术家", bundle: .module), value: L10n.artists(model.catalog.artists.count))
                LabeledContent(String(localized: "歌单", bundle: .module), value: "\(model.catalog.playlists.count)")
            }
            CatalogSyncSection(model: model, theme: theme)
            Section(String(localized: "网络音质", bundle: .module)) {
                Toggle(String(localized: "Wi-Fi 优先原始音质", bundle: .module), isOn: $highQualityWiFi)
                Text(String(localized: "开启后 Wi-Fi / 有线网络下优先使用服务器原始质量；关闭则限制码率（MP3 320kbps）以节省带宽。", bundle: .module))
                    .font(.caption)
                    .foregroundStyle(theme.colorTokens.secondaryText.color)
            }
            Section("ReplayGain") {
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
                Text("\(String(localized: "前级", bundle: .module))：\(model.replayGainSettings.preampDB, specifier: "%+.1f") dB")
                    .font(.caption)
                    .foregroundStyle(theme.colorTokens.secondaryText.color)
                Toggle(String(localized: "峰值保护", bundle: .module), isOn: Binding(
                    get: { model.replayGainSettings.peakProtection },
                    set: { model.setReplayGainPeakProtection($0) }
                ))
                Text(String(localized: "默认关闭 ReplayGain。启用后优先使用服务器返回的真实 Track/Album Gain；缺少标签时不做普通音量归一化。", bundle: .module))
                    .font(.caption)
                    .foregroundStyle(theme.colorTokens.secondaryText.color)
            }
            Section(String(localized: "离线下载", bundle: .module)) {
                LabeledContent(String(localized: "已离线", bundle: .module), value: L10n.songs(model.catalog.downloads.count))
                Text(String(localized: "用户主动下载的离线音乐与临时播放缓存分开存储；清理临时缓存不会删除已下载的音乐。", bundle: .module))
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
    @AppStorage(ExternalMusicPreferences.Keys.enabled) private var externalMusicEnabled = true
    @AppStorage(ExternalMusicPreferences.Keys.musicBrainz) private var musicBrainzEnabled = true
    @AppStorage(ExternalMusicPreferences.Keys.critiqueBrainz) private var critiqueBrainzEnabled = true
    @AppStorage(ExternalMusicPreferences.Keys.listenBrainz) private var listenBrainzEnabled = true
    @State private var hasAPIKey = false
    @State private var isEditingAIProviderSettings = false
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
            Section(String(localized: "AI 与隐私", bundle: .module)) {
                Toggle(String(localized: "启用 AI 功能", bundle: .module), isOn: $aiEnabled)
                Toggle(String(localized: "允许发送歌曲元数据", bundle: .module), isOn: $allowsMetadata)
                Toggle(String(localized: "允许发送歌词", bundle: .module), isOn: $allowsLyrics)
                Toggle(String(localized: "允许发送播放历史摘要", bundle: .module), isOn: $allowsHistory)
            }
            Section(String(localized: "大模型", bundle: .module)) {
                let settings = AIConnectionSettings()
                LabeledContent(String(localized: "接口协议", bundle: .module), value: settings.endpointSummary)
                LabeledContent(String(localized: "模型", bundle: .module), value: settings.model)
                LabeledContent(
                    "API Key",
                    value: hasAPIKey
                        ? String(localized: "已配置 · 存于系统 Keychain", bundle: .module)
                        : String(localized: "未配置", bundle: .module)
                )
                Button(String(localized: "配置大模型…", bundle: .module)) {
                    isEditingAIProviderSettings = true
                }
                if let issue = settings.completenessError {
                    Label(issue, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(theme.colorTokens.error.color)
                }
            }
            Section(String(localized: "公开音乐数据", bundle: .module)) {
                Toggle(String(localized: "启用公开音乐数据", bundle: .module), isOn: $externalMusicEnabled)
                Toggle("MusicBrainz", isOn: $musicBrainzEnabled)
                    .disabled(!externalMusicEnabled)
                Toggle("CritiqueBrainz", isOn: $critiqueBrainzEnabled)
                    .disabled(!externalMusicEnabled)
                Toggle("ListenBrainz", isOn: $listenBrainzEnabled)
                    .disabled(!externalMusicEnabled)
                Text(String(localized: "仅在打开歌曲信息、歌曲鉴赏等需要公开音乐资料的功能时按需查询。不会上传音频文件、歌词、播放地址、NAS 密码或完整音乐库。查询结果默认缓存 14 天。", bundle: .module))
                    .font(.caption)
                    .foregroundStyle(theme.colorTokens.secondaryText.color)
                HStack {
                    Button {
                        Task { await clearExternalMusicCache() }
                    } label: {
                        if isClearingExternalMusicCache {
                            HStack { ProgressView().controlSize(.small); Text(String(localized: "正在清除…", bundle: .module)) }
                        } else {
                            Label(String(localized: "清除公开音乐数据缓存", bundle: .module), systemImage: "trash")
                        }
                    }
                    .disabled(isClearingExternalMusicCache)
                    Button(String(localized: "重置音乐身份匹配…", bundle: .module), role: .destructive) {
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
            Section(String(localized: "推荐索引 V2", bundle: .module)) {
                if isLoadingIndexStatus && indexStatus == nil {
                    HStack { ProgressView().controlSize(.small); Text(String(localized: "正在读取索引状态…", bundle: .module)) }
                } else if let status = indexStatus {
                    LabeledContent(String(localized: "已分类", bundle: .module), value: "\(status.indexedTracks) / \(status.totalTracks)")
                    LabeledContent(String(localized: "待处理", bundle: .module), value: "\(status.pendingTracks)")
                    ProgressView(value: Double(status.indexedTracks), total: Double(max(status.totalTracks, 1)))
                        .tint(theme.colorTokens.accent.color)
                    LabeledContent(String(localized: "规则版本", bundle: .module), value: status.rulesVersion)
                    LabeledContent(String(localized: "索引格式", bundle: .module), value: "V2 包 v\(LocalCatalogStore.recommendationIndexV2PackageFormatVersion)")
                    HStack {
                        Button(status.pendingTracks == 0 ? String(localized: "检查并更新索引", bundle: .module) : String(localized: "开始/继续全量索引", bundle: .module)) {
                            model.startOrContinueRecommendationIndexV2()
                        }
                        .disabled(model.catalog.activeServerID == nil || model.agentCoordinator.isRunning)
                        Button(String(localized: "导出索引…", bundle: .module)) { Task { await exportIndex() } }
                            .disabled(model.catalog.activeServerID == nil || isPerformingIndexTransfer)
                        Button(String(localized: "导入索引…", bundle: .module)) { isImportingIndex = true }
                            .disabled(model.catalog.activeServerID == nil || isPerformingIndexTransfer)
                        Button(role: .destructive) { isConfirmingIndexClear = true } label: {
                            Label(isClearingIndex ? String(localized: "正在清空索引…", bundle: .module) : String(localized: "清空索引…", bundle: .module), systemImage: "trash")
                        }
                            .disabled(model.catalog.activeServerID == nil || model.agentCoordinator.isRunning || isClearingIndex || isPerformingIndexTransfer)
                        Button(String(localized: "刷新状态", bundle: .module)) { Task { await refreshIndexStatus() } }
                    }
                } else {
                    Text(String(localized: "连接并同步音乐库后，可查看索引进度。", bundle: .module))
                        .font(.caption)
                        .foregroundStyle(theme.colorTokens.secondaryText.color)
                    Button(String(localized: "开始全量索引", bundle: .module)) {
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
        .sheet(isPresented: $isEditingAIProviderSettings) {
            AIProviderSettingsSheet(theme: theme, hasAPIKey: $hasAPIKey)
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
        return "Auralis-\(String(localized: "推荐索引 V2", bundle: .module))-\(formatter.string(from: Date()))"
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
        externalMusicMessage = nil
        defer { isClearingExternalMusicCache = false }
        do {
            try await model.agentCoordinator.clearExternalMusicDataCache()
            externalMusicMessage = String(localized: "公开音乐数据缓存已清除（保留已核验的音乐身份）。", bundle: .module)
        } catch {
            externalMusicMessage = String(localized: "清除失败：\(error.localizedDescription)", bundle: .module)
        }
    }

    private func resetExternalMusicIdentity() async {
        isResettingExternalIdentity = true
        externalMusicMessage = nil
        defer { isResettingExternalIdentity = false }
        do {
            try await model.agentCoordinator.resetExternalMusicIdentity()
            externalMusicMessage = String(localized: "音乐身份匹配已重置；下次打开歌曲信息/鉴赏时将重新识别 MBID。", bundle: .module)
        } catch {
            externalMusicMessage = String(localized: "重置失败：\(error.localizedDescription)", bundle: .module)
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

    // MARK: - 系统

    @AppStorage("auralis.debug.crashLogEnabled") private var crashLogEnabled = true

    private var system: some View {
        Form {
            Section(String(localized: "系统集成", bundle: .module)) {
                LabeledContent(String(localized: "Siri 媒体播放", bundle: .module), value: String(localized: "已启用（AppIntents）", bundle: .module))
                LabeledContent(String(localized: "快捷指令", bundle: .module), value: String(localized: "已启用", bundle: .module))
                LabeledContent(String(localized: "后台播放", bundle: .module), value: String(localized: "已启用", bundle: .module))
            }
            Text(String(localized: "Siri 与快捷指令只使用本地资料库的名称与标识进行匹配，不会暴露服务器地址、账号或令牌。", bundle: .module))
                .font(.caption)
                .foregroundStyle(theme.colorTokens.secondaryText.color)
            SettingsBackupSection(model: model, themeStore: themeStore, theme: theme)
            Section(String(localized: "调试", bundle: .module)) {
                Toggle(String(localized: "启用崩溃日志", bundle: .module), isOn: $crashLogEnabled)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - 关于

    private var about: some View {
        Form {
            Section {
                LabeledContent(String(localized: "版本", bundle: .module), value: AppVersionInfo.display)
                LabeledContent(String(localized: "构建", bundle: .module), value: String(localized: "原生 macOS", bundle: .module))
                Text(String(localized: "Auralis · 私人音乐服务器播放器（OpenSubsonic / Navidrome）", bundle: .module))
                    .font(.caption)
                    .foregroundStyle(theme.colorTokens.secondaryText.color)
            }
        }
        .formStyle(.grouped)
    }
}

/// 上下文窗口的策略（纯逻辑，可单测）。
enum ContextTokenLimitPolicy {
    static let minValue = 4_096
    static let maxValue = AITokenLimitPresets.context.last ?? minValue
    static let presets = AITokenLimitPresets.context

    static func clamp(_ value: Int) -> Int {
        min(max(value, minValue), maxValue)
    }

    static func validationMessage(for value: Int) -> String? {
        guard value >= minValue else {
            return String(localized: "上下文窗口不能低于 \(minValue) token", bundle: .module)
        }
        guard value <= maxValue else {
            return String(localized: "上下文窗口不能高于 \(maxValue) token", bundle: .module)
        }
        return nil
    }
}

/// 单次输出上限的预设档位策略。
enum OutputTokenLimitPolicy {
    static let presets = AITokenLimitPresets.output

    static let minValue = 512
    static let maxValue = AITokenLimitPresets.output.last ?? minValue

    static func containsPreset(_ value: Int) -> Bool {
        presets.contains(value)
    }

    static func clamp(_ value: Int) -> Int {
        min(max(value, minValue), maxValue)
    }

    static func validationMessage(for value: Int) -> String? {
        guard value >= minValue else {
            return String(localized: "单次输出不能低于 \(minValue) token", bundle: .module)
        }
        guard value <= maxValue else {
            return String(localized: "单次输出不能高于 \(maxValue) token", bundle: .module)
        }
        return nil
    }
}

/// 单次输出上限的输入模式。
enum OutputTokenMode: String, CaseIterable, Identifiable {
    case preset
    case custom
    var id: String { rawValue }
}

#endif
