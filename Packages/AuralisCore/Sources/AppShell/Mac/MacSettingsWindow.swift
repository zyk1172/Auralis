#if os(macOS)
import DesignSystem
import SecurityKit
import SwiftUI
import ThemeEngine

/// macOS 独立设置窗口（Settings Scene）。顶部分类工具栏，内容按分类拆分，不使用 iOS 长列表。
public struct MacSettingsWindow: View {
    public init(model: AuralisAppModel, themeStore: ThemeStore) {
        self.model = model
        self.themeStore = themeStore
    }
    @ObservedObject var model: AuralisAppModel
    @ObservedObject var themeStore: ThemeStore
    @State private var category: Category = .general

    private enum Category: String, CaseIterable, Identifiable {
        case general, server, library, cache, downloads, ai, shortcuts, advanced, about
        var id: String { rawValue }
        var title: String {
            switch self {
            case .general: "通用"
            case .server: "服务器"
            case .library: "音乐库"
            case .cache: "缓存"
            case .downloads: "下载"
            case .ai: "AI 助手"
            case .shortcuts: "快捷指令与 Siri"
            case .advanced: "高级"
            case .about: "关于"
            }
        }
        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .server: "server.rack"
            case .library: "music.note.list"
            case .cache: "externaldrive"
            case .downloads: "arrow.down.circle"
            case .ai: "sparkles"
            case .shortcuts: "command"
            case .advanced: "wrench.and.screwdriver"
            case .about: "info.circle"
            }
        }
    }

    private var theme: BuiltInTheme { themeStore.current }

    public var body: some View {
        TabView(selection: $category) {
            general.tabItem { Label(Category.general.title, systemImage: Category.general.symbol) }.tag(Category.general)
            server.tabItem { Label(Category.server.title, systemImage: Category.server.symbol) }.tag(Category.server)
            library.tabItem { Label(Category.library.title, systemImage: Category.library.symbol) }.tag(Category.library)
            cache.tabItem { Label(Category.cache.title, systemImage: Category.cache.symbol) }.tag(Category.cache)
            downloads.tabItem { Label(Category.downloads.title, systemImage: Category.downloads.symbol) }.tag(Category.downloads)
            ai.tabItem { Label(Category.ai.title, systemImage: Category.ai.symbol) }.tag(Category.ai)
            shortcuts.tabItem { Label(Category.shortcuts.title, systemImage: Category.shortcuts.symbol) }.tag(Category.shortcuts)
            advanced.tabItem { Label(Category.advanced.title, systemImage: Category.advanced.symbol) }.tag(Category.advanced)
            about.tabItem { Label(Category.about.title, systemImage: Category.about.symbol) }.tag(Category.about)
        }
        .frame(width: 720, height: 540)
        .padding(0)
    }

    // MARK: - 通用

    private var general: some View {
        Form {
            Section("主题") {
                Picker("主题外观", selection: themeSelection) {
                    ForEach(themeStore.themes) { candidate in
                        Text(candidate.name).tag(candidate.id)
                    }
                }
                .pickerStyle(.menu)
                ThemeSwatchGrid(colors: theme.colorTokens, name: theme.name)
            }
        }
        .formStyle(.grouped)
    }

    private var themeSelection: Binding<String> {
        Binding(
            get: { themeStore.selectedID },
            set: { themeStore.select(id: $0) }
        )
    }

    // MARK: - 服务器

    private var server: some View {
        MacServerPage(model: model, theme: theme)
    }

    // MARK: - 音乐库

    private var library: some View {
        Form {
            Section("资料库统计") {
                LabeledContent("歌曲", value: "\(model.catalog.tracks.count) 首")
                LabeledContent("专辑", value: "\(model.catalog.albums.count) 张")
                LabeledContent("艺术家", value: "\(model.catalog.artists.count) 位")
                LabeledContent("歌单", value: "\(model.catalog.playlists.count) 个")
            }
            CatalogSyncSection(model: model, theme: theme)
        }
        .formStyle(.grouped)
    }

    // MARK: - 缓存

    private var cache: some View {
        Form {
            CacheManagementSection(model: model, theme: theme)
        }
        .formStyle(.grouped)
    }

    // MARK: - 下载

    private var downloads: some View {
        Form {
            Section("离线下载") {
                LabeledContent("已离线", value: "\(model.catalog.downloads.count) 首")
                Text("用户主动下载的离线音乐与临时播放缓存分开存储；清理临时缓存不会删除已下载的音乐。")
                    .font(.caption)
                    .foregroundStyle(theme.colorTokens.secondaryText.color)
            }
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
    @State private var hasAPIKey = false

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
            MovipNoteSettingsSection()
        }
        .formStyle(.grouped)
        .task {
            hasAPIKey = (try? await KeychainCredentialVault().retrieve(id: AIConnectionSettings.credentialID)) != nil
        }
    }

    // MARK: - 快捷指令与 Siri

    private var shortcuts: some View {
        Form {
            Section("系统集成") {
                LabeledContent("Siri 媒体播放", value: "已启用（AppIntents）")
                LabeledContent("快捷指令", value: "已启用")
                LabeledContent("后台播放", value: "已启用")
                LabeledContent("本地网络权限", value: "首次连接局域网服务器时请求")
            }
            Text("Siri 与快捷指令只使用本地资料库的名称与标识进行匹配，不会暴露服务器地址、账号或令牌。")
                .font(.caption)
                .foregroundStyle(theme.colorTokens.secondaryText.color)
        }
        .formStyle(.grouped)
    }

    // MARK: - 高级

    @AppStorage("auralis.debug.crashLogEnabled") private var crashLogEnabled = true

    private var advanced: some View {
        Form {
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
                LabeledContent("版本", value: "0.3.4")
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
