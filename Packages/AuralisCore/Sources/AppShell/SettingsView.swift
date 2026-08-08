import Application
import DesignSystem
import Domain
import LocalCatalog
import SecurityKit
import SwiftUI
import ThemeEngine
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

/// 连接测试结果。用自定义枚举而非 `Result<String, String>`，因为
/// `Result` 的 `Failure` 必须符合 `Error`，而 `String` 不符合。
private enum ConnectionTestResult {
    case success(String)
    case failure(String)
}

struct SettingsView: View {
    @ObservedObject var model: AuralisAppModel
    @ObservedObject var themeStore: ThemeStore
    @AppStorage("auralis.ai.enabled") private var aiEnabled = true
    @AppStorage("auralis.ai.allowsMetadata") private var allowsMetadata = true
    @AppStorage("auralis.ai.allowsLyrics") private var allowsLyrics = false
    @AppStorage("auralis.ai.allowsHistory") private var allowsHistory = false
    @AppStorage("auralis.audio.highQualityWiFi") private var highQualityWiFi = true
    @AppStorage("auralis.audio.cellularTranscoding") private var cellularTranscoding = true
    @AppStorage(AIConnectionSettings.Keys.baseURL) private var aiBaseURL = AIConnectionSettings.defaultBaseURL
    @AppStorage(AIConnectionSettings.Keys.model) private var aiModel = AIConnectionSettings.defaultModel
    @State private var isAddingServer = false
    @State private var isConfiguringAIProvider = false
    @State private var hasAPIKey = false
    @State private var pingResult: Bool?
    @State private var isRemovingServer = false
    @State private var savedServers: [ServerAccount] = []
    @State private var serverToSwitch: ServerAccount?
    @State private var serverToRename: ServerAccount?
    @State private var renameServerText = ""
    @AppStorage("auralis.debug.crashLogEnabled") private var crashLogEnabled = true

    private let credentialVault = KeychainCredentialVault()

    private var theme: BuiltInTheme { themeStore.current }

    var body: some View {
        Form {
            Section("主题") {
                Picker("主题外观", selection: themeSelection) {
                    ForEach(themeStore.themes) { candidate in
                        Text(candidate.name).tag(candidate.id)
                    }
                }
                .pickerStyle(.menu)
                // 当前主题色板预览（8 个核心色 Token）
                ThemeSwatchGrid(colors: theme.colorTokens, name: theme.name)
                Text("主题由共享 Design Token 驱动；页面结构不会为主题复制。跟随系统、定时与主题 JSON 导入将在后续阶段实现。")
                    .font(.caption)
                    .foregroundStyle(theme.colorTokens.secondaryText.color)
            }
            Section("服务器") {
                serverStatus
                if !savedServers.isEmpty {
                    ForEach(savedServers) { server in
                        serverRow(server)
                    }
                }
                Button("添加 OpenSubsonic 服务器") { isAddingServer = true }
                if case .connected = model.serverConnectionState {
                    Button("更换服务器") { isAddingServer = true }
                    Button("测试连接") {
                        Task { pingResult = await model.testActiveServerConnection() }
                    }
                    if let pingResult {
                        Label(
                            pingResult ? "服务器可达" : "服务器无响应",
                            systemImage: pingResult ? "checkmark.circle.fill" : "xmark.octagon.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(pingResult ? theme.colorTokens.success.color : theme.colorTokens.error.color)
                    }
                    if model.serverAuthenticationFailed {
                        Label("认证可能已失效，请重新登录", systemImage: "exclamationmark.shield.fill")
                            .font(.caption)
                            .foregroundStyle(theme.colorTokens.warning.color)
                        Button("重新登录") { isAddingServer = true }
                    }
                    Button("移除服务器（仅本机）", role: .destructive) { isRemovingServer = true }
                }
                Text("凭据只保存在系统 Keychain，不会写入日志、不会发送给大模型。移除服务器只清理本机数据，NAS 上的音乐不受影响。")
                    .font(.caption)
                    .foregroundStyle(theme.colorTokens.secondaryText.color)
            }
            CatalogSyncSection(model: model, theme: theme)
            CacheManagementSection(model: model, theme: theme)
            Section("OpenAI 兼容接口") {
                LabeledContent("Base URL", value: aiBaseURL)
                LabeledContent("模型", value: aiModel)
                LabeledContent("API Key", value: hasAPIKey ? "已配置 · 存于系统 Keychain" : "未配置")
                #if os(iOS)
                // iOS 上从 Form 直接弹 sheet 存在点击无响应的问题，改为推入整页
                NavigationLink("配置接口…") {
                    AIProviderSettingsPage(theme: theme, hasAPIKey: $hasAPIKey)
                }
                #else
                Button("配置接口…") { isConfiguringAIProvider = true }
                #endif
            }
            AgentMemoryManagementSection(model: model, theme: theme)
            MoviePilotSettingsSection()
            SettingsBackupSection(model: model, themeStore: themeStore, theme: theme)
            Section("关于") {
                LabeledContent("版本", value: "0.3.4")
            }

            // 二级设置：默认收起，避免一屏拉到底。
            DisclosureGroup("播放与音质") {
                Toggle("Wi-Fi 优先原始音质", isOn: $highQualityWiFi)
                Toggle("蜂窝网络允许转码", isOn: $cellularTranscoding)
                Toggle("显示迷你播放条", isOn: $model.showMiniPlayer)
            }
            DisclosureGroup("助手偏好") {
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
                Text("这些偏好用于推荐与智能队列；不会发送文件路径、服务器地址或完整日志。")
                    .font(.caption)
                    .foregroundStyle(theme.colorTokens.secondaryText.color)
            }
            DisclosureGroup("AI 与隐私") {
                Toggle("启用 AI 功能", isOn: $aiEnabled)
                Toggle("允许发送歌曲元数据", isOn: $allowsMetadata)
                Toggle("允许发送歌词", isOn: $allowsLyrics)
                Toggle("允许发送播放历史摘要", isOn: $allowsHistory)
                Text("默认不发送文件路径、NAS 地址、用户名、服务器令牌、设备标识或完整日志。")
                    .font(.caption)
                    .foregroundStyle(theme.colorTokens.secondaryText.color)
            }
            DisclosureGroup("高级") {
                Toggle("启用崩溃日志", isOn: $crashLogEnabled)
                if crashLogEnabled {
                    NavigationLink {
                        CrashLogView(theme: theme)
                    } label: {
                        Label("崩溃日志", systemImage: "doc.text.magnifyingglass")
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .padding(.bottom, AuralisSpacing.large)
        .background(theme.colorTokens.background.color)
        .task { await reloadServers() }
        .sheet(isPresented: $isAddingServer) {
            ServerConnectionSheet(model: model, theme: theme)
        }
        .alert("重命名服务器", isPresented: Binding(
            get: { serverToRename != nil },
            set: { if !$0 { serverToRename = nil } }
        )) {
            TextField("服务器名称", text: $renameServerText)
            Button("保存") {
                guard let server = serverToRename else { return }
                serverToRename = nil
                let name = renameServerText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty {
                    Task {
                        _ = await model.renameServer(serverID: server.id, to: name)
                        await reloadServers()
                    }
                }
            }
            Button("取消", role: .cancel) { serverToRename = nil }
        } message: {
            Text("只修改本机显示名称，不影响服务器凭据与连接。")
        }
        .confirmationDialog(
            serverToSwitch.map { "切换到「\($0.displayName)」？" } ?? "切换服务器？",
            isPresented: Binding(
                get: { serverToSwitch != nil },
                set: { if !$0 { serverToSwitch = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("切换") {
                guard let server = serverToSwitch else { return }
                serverToSwitch = nil
                pingResult = nil
                Task {
                    await model.switchServer(serverID: server.id)
                    savedServers = (try? await model.catalogCoordinator.store.listServers()) ?? []
                }
            }
            Button("取消", role: .cancel) { serverToSwitch = nil }
        } message: {
            Text("切换后本地资料库、队列与播放会话将切换到该服务器，不会影响 NAS 上的数据。")
        }
        .sheet(isPresented: $isConfiguringAIProvider) {
            AIProviderSettingsSheet(theme: theme, hasAPIKey: $hasAPIKey)
        }
        .alert("移除服务器？", isPresented: $isRemovingServer) {
            Button("移除", role: .destructive) {
                guard let serverID = model.catalog.activeServerID else { return }
                Task {
                    await model.catalogCoordinator.purgeLocalData(serverID: serverID)
                    await model.removeServerLocally(serverID: serverID)
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将删除本机保存的登录凭据、离线目录与缓存。服务器上的音乐、歌单与收藏不会被删除。")
        }
        .task {
            hasAPIKey = (try? await credentialVault.retrieve(id: AIConnectionSettings.credentialID)) != nil
        }
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


    private var themeSelection: Binding<String> {
        Binding(
            get: { themeStore.selectedID },
            set: { themeStore.select(id: $0) }
        )
    }

    @ViewBuilder
    private var serverStatus: some View {
        switch model.serverConnectionState {
        case .idle:
            LabeledContent("当前资料库", value: "未连接服务器")
            LabeledContent("状态", value: "请添加 OpenSubsonic 服务器")
        case let .connecting(stage):
            HStack {
                ProgressView()
                Text(stage.title)
                Spacer()
            }
        case let .connected(account, serverType, serverVersion, trackCount):
            LabeledContent("当前资料库", value: account.displayName)
            LabeledContent("服务器", value: [serverType, serverVersion].compactMap { $0 }.joined(separator: " · "))
            LabeledContent("已同步", value: "\(trackCount) 首歌曲")
            capabilityRows
        case let .failed(message):
            Label("连接失败", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(theme.colorTokens.error.color)
            Text(message)
                .font(.caption)
                .foregroundStyle(theme.colorTokens.secondaryText.color)
            HStack {
                Button("再次尝试") { isAddingServer = true }
                Button("检查服务器") { isAddingServer = true }
                Button("复制错误详情") { PlatformPasteboard.copy(message) }
            }
        }
    }

    @ViewBuilder
    private var capabilityRows: some View {
        let capabilities = model.serverCapabilities
        if capabilities.supportsStructuredLyrics { Label("结构化歌词", systemImage: "quote.bubble.fill") }
        if capabilities.supportsSonicSimilarity { Label("声音相似度", systemImage: "waveform.path") }
        if capabilities.supportsIndexedQueue { Label("索引式播放队列", systemImage: "list.number") }
        if capabilities.supportsPlaybackReport { Label("播放报告", systemImage: "chart.bar.fill") }
        if capabilities.supportsTranscoding { Label("服务器转码", systemImage: "arrow.triangle.2.circlepath") }
        if capabilities.supportsTranscodeOffset { Label("转码偏移定位", systemImage: "gobackward") }
        if capabilities.supportsAPIKeyAuthentication { Label("API Key 认证", systemImage: "key.horizontal.fill") }
        if !capabilities.supportsStructuredLyrics && !capabilities.supportsSonicSimilarity
            && !capabilities.supportsIndexedQueue && !capabilities.supportsPlaybackReport
            && !capabilities.supportsTranscoding && !capabilities.supportsTranscodeOffset
            && !capabilities.supportsAPIKeyAuthentication {
            Text("服务器未声明可选扩展；澜音只显示基础 OpenSubsonic 功能。")
                .font(.caption)
                .foregroundStyle(theme.colorTokens.secondaryText.color)
        }
    }
    /// 已保存服务器列表行：当前服务器显示标记，其余可切换（需确认）。
    @ViewBuilder
    private func serverRow(_ server: ServerAccount) -> some View {
        let isActive = model.catalog.activeServerID == server.id
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(server.displayName)
                        .font(.body)
                    if isActive {
                        Label("当前", systemImage: "checkmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(theme.colorTokens.success.color)
                    }
                }
                Text(server.baseURL?.host ?? server.username ?? "本地资料库")
                    .font(.caption)
                    .foregroundStyle(theme.colorTokens.secondaryText.color)
                    .lineLimit(1)
            }
            Spacer()
            Menu {
                Button {
                    renameServerText = server.displayName
                    serverToRename = server
                } label: { Label("重命名", systemImage: "pencil") }
                if !isActive {
                    Button("切换到此服务器") { serverToSwitch = server }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("服务器操作")
        }
        .contentShape(Rectangle())
    }

    private func reloadServers() async {
        savedServers = (try? await model.catalogCoordinator.store.listServers()) ?? []
    }


}

struct ServerConnectionSheet: View {
    @ObservedObject var model: AuralisAppModel
    let theme: BuiltInTheme
    @Environment(\.dismiss) private var dismiss
    @State private var displayName = ""
    @State private var serverURL = ""
    @State private var username = ""
    @State private var password = ""
    @State private var localValidationError: String?
    @State private var connectionTask: Task<Void, Never>?
    @State private var isTesting = false
    private enum TestResultDisplay {
        case success(String)
        case failure(String)
    }
    @State private var testResult: TestResultDisplay?
#if DEBUG
    @State private var probeResult: LocalNetworkProbeResult?
    @State private var isProbing = false
#endif

    var body: some View {
        NavigationStack {
            Form {
                Section("OpenSubsonic 服务器") {
                    TextField("显示名称", text: $displayName)
                        .textContentType(.organizationName)
                    TextField("http://192.168.2.240:3000", text: $serverURL)
#if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
#endif
                        .autocorrectionDisabled()
                    TextField("用户名", text: $username)
#if os(iOS)
                        .textInputAutocapitalization(.never)
#endif
                        .autocorrectionDisabled()
                    SecureField("密码", text: $password)
                        .textContentType(.password)
                }
                Section("连接测试") {
                    Button {
                        Task { await runTest() }
                    } label: {
                        if isTesting {
                            HStack {
                                ProgressView().controlSize(.small)
                                Text("正在测试…")
                            }
                        } else {
                            Label("测试连接", systemImage: "network")
                        }
                    }
                    .disabled(isTesting || model.serverConnectionState.isConnecting)
                    Text("首次连接局域网服务器时，系统会自动弹出「本地网络」授权；若之前拒绝过，请点「打开本地网络设置」允许后重试。")
                        .font(.caption2)
                        .foregroundStyle(theme.colorTokens.secondaryText.color)
                    if let testResult {
                        switch testResult {
                        case let .success(message):
                            Label(message, systemImage: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(theme.colorTokens.success.color)
                        case let .failure(message):
                            VStack(alignment: .leading, spacing: 4) {
                                Label("连接失败", systemImage: "xmark.octagon.fill")
                                    .foregroundStyle(theme.colorTokens.error.color)
                                Text(message)
                                    .font(.caption)
                                    .foregroundStyle(theme.colorTokens.secondaryText.color)
                                    .lineLimit(nil)
                                    .textSelection(.enabled)
                                if message.contains("本地网络") {
                                    Button("打开本地网络设置") {
                                        PlatformLocalNetworkSettings.open()
                                    }
                                    .font(.caption)
                                }
                            }
                        }
                    }
                }
                Section("连接安全") {
                    Label("凭据仅写入系统 Keychain", systemImage: "key.fill")
                    Label("HTTP 仅允许本机或私有局域网", systemImage: "network")
                    Text("公共服务器必须使用 HTTPS。澜音不会记录密码、认证 Token 或完整请求地址。")
                        .font(.caption)
                        .foregroundStyle(theme.colorTokens.secondaryText.color)
                }
#if DEBUG
                Section("本地网络探测（DEBUG）") {
                    Button {
                        Task { await runProbe() }
                    } label: {
                        if isProbing {
                            HStack {
                                ProgressView().controlSize(.small)
                                Text("正在探测…")
                            }
                        } else {
                            Label("NWConnection 探测", systemImage: "network")
                        }
                    }
                    .disabled(isProbing)
                    if let probeResult {
                        LabeledContent("TCP 状态", value: probeResult.state.rawValue)
                        LabeledContent("unsatisfiedReason", value: probeResult.unsatisfiedReason ?? "—")
                        if probeResult.isLocalNetworkDenied {
                            Label("Local Network Privacy: DENIED / BLOCKED", systemImage: "xmark.octagon.fill")
                                .foregroundStyle(theme.colorTokens.error.color)
                        } else if probeResult.state == .ready {
                            Label("Local Network TCP: AVAILABLE", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(theme.colorTokens.success.color)
                        }
                        if let err = probeResult.errorDescription, !err.isEmpty {
                            diagnosticLongValue("错误详情", err)
                        }
                        Text("探测时间 \(probeResult.timestamp.formatted(date: .omitted, time: .standard))")
                            .font(.caption2)
                            .foregroundStyle(theme.colorTokens.secondaryText.color)
                    }
                }
#endif
                if let localValidationError {
                    Section("需要处理") {
                        Label(localValidationError, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(theme.colorTokens.error.color)
                    }
                }
                if case let .connecting(stage) = model.serverConnectionState {
                    Section("连接进度") {
                        HStack {
                            ProgressView()
                            Text(stage.title)
                        }
                    }
                }
                if case let .failed(message) = model.serverConnectionState {
                    Section("连接失败") {
                        Text(message)
                            .lineLimit(nil)
                            .textSelection(.enabled)
                        if message.contains("本地网络") {
                            Button("打开本地网络设置") {
                                PlatformLocalNetworkSettings.open()
                            }
                        }
                        Button("复制错误详情") { PlatformPasteboard.copy(message) }
                    }
                }
                #if DEBUG
                if let diag = model.connectionDiagnostics {
                    Section("网络诊断（DEBUG）") {
                        LabeledContent("App Bundle ID", value: AppDiagnostics.bundleID)
                        LabeledContent("Target", value: AppDiagnostics.targetKind)
                        LabeledContent("App Sandbox", value: AppDiagnostics.isAppSandboxEnabled ? "已启用" : "未启用")
                        LabeledContent("network.client（出站连接）") {
                            Text(AppDiagnostics.hasNetworkClientEntitlement ? "存在" : "未检测到（可用 codesign -d --entitlements 复核）")
                                .textSelection(.enabled)
                                .lineLimit(nil)
                        }
                        LabeledContent("NSLocalNetworkUsageDescription", value: (AppDiagnostics.localNetworkUsageDescription?.isEmpty == false) ? "已声明" : "缺失")
                        LabeledContent("服务器 Host", value: diag.host ?? "—")
                        LabeledContent("局域网地址", value: diag.isPrivateLAN ? "是" : "否")
                        LabeledContent("协议", value: diag.scheme?.uppercased() ?? "—")
                        LabeledContent("测试/连接请求已发出", value: diag.requestAttempted ? "是" : "否")
                        if let domain = diag.nsErrorDomain {
                            LabeledContent("NSError domain") {
                                Text("\(domain)（code \(diag.nsErrorCode ?? -1)）")
                                    .textSelection(.enabled)
                                    .lineLimit(nil)
                            }
                        }
                        if let desc = diag.nsErrorDescription, !desc.isEmpty {
                            diagnosticLongValue("错误描述", desc)
                        }
                        if let failing = diag.failingURL, !failing.isEmpty {
                            diagnosticLongValue("failingURL", failing)
                        }
                        if let underlying = diag.underlyingError, !underlying.isEmpty {
                            diagnosticLongValue("underlyingError", underlying)
                        }
                        LabeledContent("映射结果") {
                            Text(diag.mappedMessage)
                                .textSelection(.enabled)
                                .lineLimit(nil)
                        }
                        Text("诊断时间 \(diag.timestamp.formatted(date: .omitted, time: .standard))")
                            .font(.caption2)
                            .foregroundStyle(theme.colorTokens.secondaryText.color)
                    }
                }
                #endif
            }
            .navigationTitle("添加服务器")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(model.serverConnectionState.isConnecting ? "停止" : "取消") {
                        connectionTask?.cancel()
                        connectionTask = nil
                        password = ""
                        if !model.serverConnectionState.isConnecting { dismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", action: connect)
                        .disabled(model.serverConnectionState.isConnecting)
                }
            }
            .onChange(of: model.serverConnectionState) { _, state in
                if case .connected = state {
                    connectionTask = nil
                    password = ""
                    dismiss()
                } else if case .failed = state {
                    connectionTask = nil
                }
            }
        }
#if os(macOS)
        // macOS 的 sheet 按内容理想高度撑开：表单内容很高（错误提示 / 网络诊断区）时会超过
        // 屏幕高度，底部被裁掉且 Form 不会滚动。这里给出有界高度（min/ideal/max），让 Form
        // 在高度不足时内部滚动，长错误信息能完整滚动查看并选中复制。
        .frame(minWidth: 460, idealWidth: 520, maxWidth: 600, minHeight: 520, idealHeight: 640, maxHeight: 700)
#endif
        .interactiveDismissDisabled(model.serverConnectionState.isConnecting)
    }

    private func connect() {
        localValidationError = nil
        guard let url = URL(string: serverURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            localValidationError = ServerConnectionError.invalidURL.localizedDescription
            return
        }
        do {
            try ServerURLPolicy.validate(url)
        } catch {
            localValidationError = error.localizedDescription
            return
        }
        let input = ServerConnectionInput(
            displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines),
            baseURL: url,
            username: username.trimmingCharacters(in: .whitespacesAndNewlines),
            password: password
        )
        connectionTask?.cancel()
        connectionTask = Task { await model.connect(to: input) }
    }

    /// 只做连接测试：不保存凭据、不同步、不关闭配置界面。
    private func runTest() async {
        isTesting = true
        testResult = nil
        defer { isTesting = false }
        let rawURL = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: rawURL) else {
            testResult = .failure(ServerConnectionError.invalidURL.localizedDescription)
            return
        }
        do {
            try ServerURLPolicy.validate(url)
            let input = ServerConnectionInput(
                displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines),
                baseURL: url,
                username: username.trimmingCharacters(in: .whitespacesAndNewlines),
                password: password
            )
            switch await model.testServerConnectionWithInput(input) {
            case let .success(message): testResult = .success(message)
            case let .failure(message): testResult = .failure(message)
            }
        } catch {
            testResult = .failure(ConnectionErrorDescription.describe(error))
        }
    }

#if DEBUG
    /// 用 NWConnection 对当前输入的服务器地址做 TCP 探测，观察本地网络隐私状态。
    private func runProbe() async {
        isProbing = true
        defer { isProbing = false }
        let rawURL = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: rawURL), let host = url.host, !host.isEmpty else {
            probeResult = LocalNetworkProbeResult(
                state: .failed,
                unsatisfiedReason: nil,
                errorDescription: "无法从服务器地址解析出 Host（示例：http://192.168.2.240:4533）",
                timestamp: .now
            )
            return
        }
        let port = UInt16(url.port ?? (url.scheme == "https" ? 443 : 80))
        probeResult = await LocalNetworkProbe.probe(host: host, port: port)
    }
#endif

    /// 网络诊断区的「长文本字段」行：标签独占一行、值完整换行显示且可选中复制，
    /// 避免 LabeledContent 的尾随值在 macOS 上被截断。
    private func diagnosticLongValue(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(theme.colorTokens.secondaryText.color)
            Text(value)
                .font(.caption)
                .foregroundStyle(theme.colorTokens.primaryText.color)
                .textSelection(.enabled)
                .lineLimit(nil)
        }
    }
}

/// OpenAI 兼容接口配置页：Base URL、API 路径、模型、API Key 与连接测试。
/// iOS 作为整页推入（NavigationLink），macOS 包一层 sheet 使用。
struct AIProviderSettingsPage: View {
    let theme: BuiltInTheme
    @Binding var hasAPIKey: Bool
    @AppStorage(AIConnectionSettings.Keys.baseURL) private var aiBaseURL = AIConnectionSettings.defaultBaseURL
    @AppStorage(AIConnectionSettings.Keys.apiPath) private var aiAPIPath = AIConnectionSettings.defaultAPIPath
    @AppStorage(AIConnectionSettings.Keys.model) private var aiModel = AIConnectionSettings.defaultModel
    @State private var isConfiguringAPIKey = false
    @State private var isTestingConnection = false
    @State private var connectionTestResult: ConnectionTestResult?

    private let credentialVault = KeychainCredentialVault()

    var body: some View {
        Form {
            Section("接口地址") {
                TextField("Base URL", text: $aiBaseURL, prompt: Text(AIConnectionSettings.defaultBaseURL))
#if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
#endif
                    .autocorrectionDisabled()
                TextField("API 路径", text: $aiAPIPath, prompt: Text(AIConnectionSettings.defaultAPIPath))
#if os(iOS)
                    .textInputAutocapitalization(.never)
#endif
                    .autocorrectionDisabled()
                TextField("模型", text: $aiModel, prompt: Text(AIConnectionSettings.defaultModel))
#if os(iOS)
                    .textInputAutocapitalization(.never)
#endif
                    .autocorrectionDisabled()
            }
            Section("API Key") {
                LabeledContent("状态", value: hasAPIKey ? "已配置 · 存于系统 Keychain" : "未配置")
                HStack {
                    #if os(iOS)
                    NavigationLink(hasAPIKey ? "更新 API Key" : "配置 API Key") {
                        APIKeyPage(theme: theme, hasExistingKey: hasAPIKey) { key in
                            try await credentialVault.store(key, for: AIConnectionSettings.credentialID)
                            hasAPIKey = true
                        }
                    }
                    #else
                    Button(hasAPIKey ? "更新 API Key" : "配置 API Key") { isConfiguringAPIKey = true }
                    #endif
                    if hasAPIKey {
                        Spacer()
                        Button("删除", role: .destructive) {
                            Task {
                                try? await credentialVault.delete(id: AIConnectionSettings.credentialID)
                                hasAPIKey = false
                            }
                        }
                    }
                }
            }
            Section("连接测试") {
                HStack {
                    Button(action: testAIConnection) {
                        if isTestingConnection {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("测试连接")
                        }
                    }
                    .disabled(isTestingConnection || !AIConnectionSettings().isComplete)
                    if let issue = AIConnectionSettings().completenessError {
                        Text(issue)
                            .font(.caption)
                            .foregroundStyle(theme.colorTokens.secondaryText.color)
                    }
                }
                if let connectionTestResult {
                    switch connectionTestResult {
                    case let .success(message):
                        Label(message, systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(theme.colorTokens.success.color)
                    case let .failure(message):
                        Label(message, systemImage: "xmark.octagon.fill")
                            .font(.caption)
                            .foregroundStyle(theme.colorTokens.error.color)
                    }
                }
            }
            Section {
                Text("任何兼容 OpenAI Chat Completions 的服务都可使用：OpenAI、DeepSeek、通义千问、Kimi、Ollama、LM Studio 及各类中转网关。API Key 仅写入系统 Keychain，不同步；仅在「设置备份」导出时会以加密形式包含（见备份密码保护）。")
                    .font(.caption)
                    .foregroundStyle(theme.colorTokens.secondaryText.color)
            }
        }
        .navigationTitle("OpenAI 兼容接口")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
#if os(macOS)
        .sheet(isPresented: $isConfiguringAPIKey) {
            APIKeySheet(
                theme: theme,
                hasExistingKey: hasAPIKey,
                onSave: { key in
                    try await credentialVault.store(key, for: AIConnectionSettings.credentialID)
                    hasAPIKey = true
                }
            )
        }
#endif
    }

    private func testAIConnection() {
        guard let provider = AIConnectionSettings().makeProvider(credentialVault: credentialVault) else {
            connectionTestResult = .failure("Base URL 或模型未填写完整。")
            return
        }
        isTestingConnection = true
        connectionTestResult = nil
        Task {
            do {
                let result = try await provider.testConnection()
                connectionTestResult = .success("连接成功 · \(result.model) · 延迟 \(String(format: "%.1f", result.latency)) 秒")
            } catch {
                connectionTestResult = .failure(error.localizedDescription)
            }
            isTestingConnection = false
        }
    }


}

/// macOS 的弹窗包装：iOS 直接推入 AIProviderSettingsPage，不经过 sheet。
private struct AIProviderSettingsSheet: View {
    let theme: BuiltInTheme
    @Binding var hasAPIKey: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            AIProviderSettingsPage(theme: theme, hasAPIKey: $hasAPIKey)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { dismiss() }
                    }
                }
        }
#if os(macOS)
        .frame(minWidth: 480, minHeight: 560)
#endif
    }
}

/// API Key 编辑页：iOS 推入、macOS 包 sheet（见 APIKeySheet）。
struct APIKeyPage: View {
    let theme: BuiltInTheme
    let hasExistingKey: Bool
    let onSave: (String) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var apiKey = ""
    @State private var isSaving = false
    @State private var saveError: String?

    var body: some View {
        Form {
            Section("AI Provider API Key") {
                SecureField("sk-...", text: $apiKey)
#if os(iOS)
                    .textInputAutocapitalization(.never)
#endif
                    .autocorrectionDisabled()
            }
            Section("存储安全") {
                Label("仅写入系统 Keychain（本机、不同步）", systemImage: "key.fill")
                if hasExistingKey {
                    Label("保存后将覆盖已存储的 Key", systemImage: "arrow.triangle.2.circlepath")
                }
            }
            if let saveError {
                Section("需要处理") {
                    Label(saveError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(theme.colorTokens.error.color)
                }
            }
        }
        .navigationTitle(hasExistingKey ? "更新 API Key" : "配置 API Key")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("存储到 Keychain", action: save)
                    .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
            }
        }
        .interactiveDismissDisabled(isSaving)
    }

    private func save() {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        isSaving = true
        saveError = nil
        Task {
            do {
                try await onSave(key)
                isSaving = false
                dismiss()
            } catch {
                isSaving = false
                saveError = "写入 Keychain 失败，请检查系统钥匙串访问权限。"
            }
        }
    }
}

/// macOS 的 API Key 弹窗包装。
private struct APIKeySheet: View {
    let theme: BuiltInTheme
    let hasExistingKey: Bool
    let onSave: (String) async throws -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            APIKeyPage(theme: theme, hasExistingKey: hasExistingKey, onSave: onSave)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { dismiss() }
                    }
                }
        }
#if os(macOS)
        .frame(minWidth: 420, minHeight: 320)
#endif
    }
}


private enum PlatformPasteboard {
    static func copy(_ value: String) {
#if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
#elseif os(iOS)
        UIPasteboard.general.string = value
#endif
    }
}
