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
            SettingsBackupSection(model: model, themeStore: themeStore, theme: theme)
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
    @AppStorage(AIConnectionSettings.Keys.baseURL) private var aiBaseURL = AIConnectionSettings.defaultBaseURL
    @AppStorage(AIConnectionSettings.Keys.model) private var aiModel = AIConnectionSettings.defaultModel
    @State private var hasAPIKey = false
    @State private var indexStatus: RecommendationIndexV2Status?
    @State private var isLoadingIndexStatus = false

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
                    Button {
                        model.startOrContinueRecommendationIndexV2()
                    } label: {
                        Label(
                            status.pendingTracks == 0 ? "检查并更新索引" : "开始/继续全量索引",
                            systemImage: "sparkles.rectangle.stack"
                        )
                    }
                    .disabled(model.catalog.activeServerID == nil || model.agentCoordinator.isRunning)
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
            AgentMemoryManagementSection(model: model, theme: theme)
        }
        .task {
            hasAPIKey = (try? await credentialVault.retrieve(id: AIConnectionSettings.credentialID)) != nil
            await refreshIndexStatus()
        }
        .task(id: model.catalog.activeServerID) { await refreshIndexStatus() }
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
