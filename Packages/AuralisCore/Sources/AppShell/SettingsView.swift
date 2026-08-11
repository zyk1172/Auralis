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
    @State private var isEditingHomeLayout = false
    @Environment(\.bottomDockReservedHeight) private var bottomDockReservedHeight

    private var theme: BuiltInTheme { themeStore.current }

    var body: some View {
        Form {
            Section("设置") {
                NavigationLink {
                    ServerSettingsPage(model: model, theme: theme)
                } label: {
                    SettingsCategoryRow(
                        title: "服务器",
                        subtitle: model.catalog.isConnected ? "已连接 · \(model.catalog.tracks.count) 首歌曲" : "连接音乐服务器与下载服务",
                        icon: "server.rack"
                    )
                }
                NavigationLink {
                    AgentSettingsPage(model: model, theme: theme)
                } label: {
                    SettingsCategoryRow(
                        title: "Agent",
                        subtitle: aiEnabled ? "大模型、推荐索引与隐私" : "已关闭",
                        icon: "sparkles"
                    )
                }
                NavigationLink {
                    PlaybackSettingsPage(model: model, theme: theme)
                } label: {
                    SettingsCategoryRow(title: "播放与音质", subtitle: "网络音质与迷你播放条", icon: "speaker.wave.2")
                }
                NavigationLink {
                    DataSettingsPage(model: model, themeStore: themeStore, theme: theme)
                } label: {
                    SettingsCategoryRow(title: "数据与备份", subtitle: "本地缓存与配置备份", icon: "externaldrive")
                }
            }
            Section("外观") {
                Button {
                    isEditingHomeLayout = true
                } label: {
                    SettingsCategoryRow(
                        title: "首页布局",
                        subtitle: "模块显示与排序",
                        icon: "slider.horizontal.3"
                    )
                }
                .buttonStyle(HapticPlainButtonStyle())
                NavigationLink {
                    ThemeSettingsPage(themeStore: themeStore)
                } label: {
                    SettingsCategoryRow(title: "主题", subtitle: theme.name, icon: "paintpalette")
                }
            }
            Section("关于") {
                LabeledContent("版本", value: AppVersionInfo.display)
            }
        }
        .scrollContentBackground(.hidden)
        // 悬浮 Dock 不参与 NavigationStack 的安全区计算。为 Form 的末项预留同一高度，
        // 滚到底时不会再被栏位遮挡。
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear.frame(height: bottomDockReservedHeight)
        }
        .background(theme.colorTokens.background.color)
        .sheet(isPresented: $isEditingHomeLayout) {
            HomeLayoutEditView(model: model, theme: theme)
        }
    }
}
/// 编辑既有服务器：仅更新本机的连接资料，不重新建库也不删除已同步歌曲。
struct ServerEditSheet: View {
    @ObservedObject var model: AuralisAppModel
    let theme: BuiltInTheme
    let server: ServerAccount
    let onSaved: @MainActor () async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var displayName: String
    @State private var internalURL: String
    @State private var externalURL: String
    @State private var username: String
    @State private var password = ""
    @State private var errorMessage: String?
    @State private var isSaving = false

    init(
        model: AuralisAppModel,
        theme: BuiltInTheme,
        server: ServerAccount,
        onSaved: @escaping @MainActor () async -> Void
    ) {
        self.model = model
        self.theme = theme
        self.server = server
        self.onSaved = onSaved
        _displayName = State(initialValue: server.displayName)
        _internalURL = State(initialValue: server.baseURL?.absoluteString ?? "")
        _externalURL = State(initialValue: server.externalBaseURL?.absoluteString ?? "")
        _username = State(initialValue: server.username ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("服务器信息") {
                    TextField("显示名称", text: $displayName)
                    TextField("内网服务器地址", text: $internalURL)
                        .autocorrectionDisabled()
                    TextField("外网服务器地址（可选）", text: $externalURL)
                        .autocorrectionDisabled()
                    TextField("用户名", text: $username)
                        .autocorrectionDisabled()
                    SecureField("新密码（留空则不修改）", text: $password)
                }
                Section {
                    Text("内网和外网会同时探测。内网在 30 秒内可达时优先使用；只有内网确认不可达时才使用外网。")
                        .font(.caption)
                        .foregroundStyle(theme.colorTokens.secondaryText.color)
                    Text("修改地址不会新建重复服务器，也不会删除本机已同步的音乐库。")
                        .font(.caption)
                        .foregroundStyle(theme.colorTokens.secondaryText.color)
                }
                if let errorMessage {
                    Section("无法保存") {
                        Text(errorMessage)
                            .foregroundStyle(theme.colorTokens.error.color)
                    }
                }
            }
            .navigationTitle("编辑服务器")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "保存中…" : "保存") { Task { await save() } }
                        .disabled(isSaving)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, idealWidth: 540, minHeight: 430)
        #endif
    }

    @MainActor
    private func save() async {
        errorMessage = nil
        guard let internalEndpoint = URL(string: internalURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            errorMessage = ServerConnectionError.invalidURL.localizedDescription
            return
        }
        let externalEndpoint: URL?
        let rawExternal = externalURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if rawExternal.isEmpty {
            externalEndpoint = nil
        } else if let parsed = URL(string: rawExternal) {
            externalEndpoint = parsed
        } else {
            errorMessage = ServerConnectionError.invalidURL.localizedDescription
            return
        }
        do {
            try ServerURLPolicy.validate(internalEndpoint)
            if let externalEndpoint { try ServerURLPolicy.validate(externalEndpoint) }
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        isSaving = true
        defer { isSaving = false }
        let update = ServerConfigurationUpdate(
            displayName: displayName,
            baseURL: internalEndpoint,
            externalBaseURL: externalEndpoint,
            username: username,
            password: password.isEmpty ? nil : password
        )
        guard await model.updateServerConfiguration(serverID: server.id, update: update) else {
            errorMessage = "无法保存服务器设置，请检查名称、用户名和系统 Keychain。"
            return
        }
        await onSaved()
        dismiss()
    }
}

struct ServerConnectionSheet: View {
    @ObservedObject var model: AuralisAppModel
    let theme: BuiltInTheme
    @Environment(\.dismiss) private var dismiss
    @State private var displayName = ""
    @State private var serverURL = ""
    @State private var externalServerURL = ""
    @State private var username = ""
    @State private var password = ""
    @State private var localValidationError: String?
    @State private var connectionTask: Task<Void, Never>?
    @State private var isTesting = false
    @State private var isRequestingLocalNetworkAuthorization = false
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
                    TextField("内网服务器地址（如 http://192.168.2.240:3000）", text: $serverURL)
#if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
#endif
                        .autocorrectionDisabled()
                    TextField("外网服务器地址（可选）", text: $externalServerURL)
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
                        if isTesting || isRequestingLocalNetworkAuthorization {
                            HStack {
                                ProgressView().controlSize(.small)
                                Text(isRequestingLocalNetworkAuthorization ? "正在请求本地网络访问…" : "正在测试…")
                            }
                        } else {
                            Label("测试连接", systemImage: "network")
                        }
                    }
                    .disabled(isTesting || isRequestingLocalNetworkAuthorization || model.serverConnectionState.isConnecting)
                    Text("内网与外网会同时探测；内网在 30 秒内可用时始终优先使用，确认不可用后才降级外网。首次连接局域网服务器时，澜音会自动请求「本地网络」授权。")
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
                // 测试连接已在上方展示同一错误时，不重复占用一整段表单空间；
                // 点击“保存”时仍在这里显示校验/授权失败原因。
                if let localValidationError, case nil = testResult {
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
        let externalURL: URL?
        let rawExternalURL = externalServerURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if rawExternalURL.isEmpty {
            externalURL = nil
        } else if let parsed = URL(string: rawExternalURL) {
            do {
                try ServerURLPolicy.validate(parsed)
                externalURL = parsed
            } catch {
                localValidationError = error.localizedDescription
                return
            }
        } else {
            localValidationError = ServerConnectionError.invalidURL.localizedDescription
            return
        }
        let input = ServerConnectionInput(
            displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines),
            baseURL: url,
            externalBaseURL: externalURL,
            username: username.trimmingCharacters(in: .whitespacesAndNewlines),
            password: password
        )
        connectionTask?.cancel()
        connectionTask = Task { @MainActor in
            guard await requestLocalNetworkAuthorizationIfNeeded(for: url) else { return }
            guard !Task.isCancelled else { return }
            await model.connect(to: input)
        }
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
            guard await requestLocalNetworkAuthorizationIfNeeded(for: url) else {
                testResult = .failure(localValidationError ?? "本地网络访问被系统拒绝。")
                return
            }
            let rawExternalURL = externalServerURL.trimmingCharacters(in: .whitespacesAndNewlines)
            let externalURL: URL?
            if rawExternalURL.isEmpty {
                externalURL = nil
            } else if let parsed = URL(string: rawExternalURL) {
                try ServerURLPolicy.validate(parsed)
                externalURL = parsed
            } else {
                throw ServerConnectionError.invalidURL
            }
            let input = ServerConnectionInput(
                displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines),
                baseURL: url,
                externalBaseURL: externalURL,
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

    /// macOS 首次访问私有地址时，主动发起一次轻量 TCP 连接以触发系统的本地网络授权。
    /// 非局域网地址和探测超时都交由实际的 OpenSubsonic 请求处理；只有系统明确返回
    /// `localNetworkDenied` 时才阻止继续连接并提供可操作的说明。
    @MainActor
    private func requestLocalNetworkAuthorizationIfNeeded(for url: URL) async -> Bool {
#if os(macOS)
        guard let host = url.host, ServerURLPolicy.isPrivateOrLocal(host: host) else {
            return true
        }

        let port = UInt16(url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80))
        isRequestingLocalNetworkAuthorization = true
        defer { isRequestingLocalNetworkAuthorization = false }

        let result = await LocalNetworkProbe.probe(host: host, port: port, timeout: 15)
        guard result.isLocalNetworkDenied else { return true }

        localValidationError = "本地网络访问已被 macOS 拒绝。澜音会在首次连接时自动申请；若此前点过“不允许”，系统不会再次弹窗。请在“系统设置 → 隐私与安全性 → 本地网络”中打开“澜音”后重试。"
        return false
#else
        return true
#endif
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
    @AppStorage(AIConnectionSettings.Keys.maxContextTokens) private var aiMaxContextTokens = AIConnectionSettings.defaultMaxContextTokens
    @AppStorage(AIConnectionSettings.Keys.maxOutputTokens) private var aiMaxOutputTokens = AIConnectionSettings.defaultMaxOutputTokens
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
