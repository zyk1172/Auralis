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
            Section(String(localized: "设置", bundle: .module)) {
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
            Section(String(localized: "外观", bundle: .module)) {
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
            Section(String(localized: "关于", bundle: .module)) {
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
                Section(String(localized: "服务器信息", bundle: .module)) {
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
                    Text(String(localized: "内网和外网会同时探测。内网在 30 秒内可达时优先使用；只有内网确认不可达时才使用外网。", bundle: .module))
                        .font(.caption)
                        .foregroundStyle(theme.colorTokens.secondaryText.color)
                    Text(String(localized: "修改地址不会新建重复服务器，也不会删除本机已同步的音乐库。", bundle: .module))
                        .font(.caption)
                        .foregroundStyle(theme.colorTokens.secondaryText.color)
                }
                if let errorMessage {
                    Section(String(localized: "无法保存", bundle: .module)) {
                        Text(errorMessage)
                            .foregroundStyle(theme.colorTokens.error.color)
                    }
                }
            }
            .navigationTitle(String(localized: "编辑服务器", bundle: .module))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "取消", bundle: .module)) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? String(localized: "保存中…", bundle: .module) : String(localized: "保存", bundle: .module)) { Task { await save() } }
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
    private enum TestResultStatus {
        case success
        case authFailed
        case unreachable
    }
    @State private var testStatus: TestResultStatus?

    /// 底部操作栏「保存」可用性：核心字段填齐且没有正在进行的连接/测试。
    private var canSave: Bool {
        !model.serverConnectionState.isConnecting
            && !isTesting
            && !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && URL(string: serverURL.trimmingCharacters(in: .whitespacesAndNewlines)) != nil
            && !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !password.isEmpty
    }

    var body: some View {
        #if os(macOS)
        macBody
        #else
        iOSBody
        #endif
    }

    // MARK: - macOS：标准两列表单 Sheet

    #if os(macOS)
    private var macBody: some View {
        VStack(spacing: 0) {
            header
            Divider()
            formArea
                .frame(maxHeight: .infinity, alignment: .top)
            Divider()
            bottomBar
        }
        .frame(minWidth: 540, idealWidth: 560, maxWidth: 600, minHeight: 400)
        .interactiveDismissDisabled(model.serverConnectionState.isConnecting)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(String(localized: "添加服务器", bundle: .module))
                .font(.title2.bold())
                .foregroundStyle(theme.colorTokens.primaryText.color)
            Text("OpenSubsonic")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 14)
    }

    private var formArea: some View {
        VStack(alignment: .leading, spacing: 14) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                GridRow {
                    fieldLabel(String(localized: "显示名称", bundle: .module))
                    TextField("输入显示名称", text: $displayName)
                        .textFieldStyle(.roundedBorder)
                        .textContentType(.organizationName)
                        .frame(width: 320)
                }
                GridRow {
                    fieldLabel(String(localized: "服务器地址", bundle: .module))
                    TextField("输入服务器地址", text: $serverURL)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .frame(width: 320)
                }
                GridRow {
                    fieldLabel(String(localized: "用户名", bundle: .module))
                    TextField("输入用户名", text: $username)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .frame(width: 320)
                }
                GridRow {
                    fieldLabel(String(localized: "密码", bundle: .module))
                    SecureField("输入密码", text: $password)
                        .textFieldStyle(.roundedBorder)
                        .textContentType(.password)
                        .frame(width: 320)
                }
                GridRow {
                    fieldLabel(String(localized: "外网地址", bundle: .module))
                    TextField("输入外网地址", text: $externalServerURL)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .frame(width: 320)
                }
            }

            securityNotes

            // 轻量错误/进度：只在确实需要时出现，不长期占位。
            if let localValidationError, testStatus == nil {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(localValidationError)
                }
                .font(.footnote)
                .foregroundStyle(theme.colorTokens.error.color)
            }
            if case let .connecting(stage) = model.serverConnectionState {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("正在\(stage.title)…").font(.footnote).foregroundStyle(.secondary)
                }
            }
            if case let .failed(message) = model.serverConnectionState {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(message)
                }
                .font(.footnote)
                .foregroundStyle(theme.colorTokens.error.color)
                .lineLimit(2)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(theme.colorTokens.primaryText.color)
            .frame(width: 92, alignment: .trailing)
    }

    private var securityNotes: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(String(localized: "凭据安全存储在系统 Keychain 中。", bundle: .module), systemImage: "key")
            Label(String(localized: "公网服务器建议使用 HTTPS。", bundle: .module), systemImage: "lock")
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }

    private var bottomBar: some View {
        HStack(spacing: 12) {
            Button {
                Task { await runTest() }
            } label: {
                if isTesting || isRequestingLocalNetworkAuthorization {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(isRequestingLocalNetworkAuthorization ? String(localized: "正在请求本地网络访问…", bundle: .module) : String(localized: "正在测试连接…", bundle: .module))
                    }
                } else {
                    Text(String(localized: "测试连接", bundle: .module))
                }
            }
            .disabled(isTesting || isRequestingLocalNetworkAuthorization || model.serverConnectionState.isConnecting)

            if !isTesting, !isRequestingLocalNetworkAuthorization, let testStatus {
                statusLabel(testStatus)
            }

            Spacer(minLength: 0)

            Button(String(localized: "取消", bundle: .module)) { cancelOrStop() }
                .disabled(model.serverConnectionState.isConnecting)
            Button(String(localized: "保存", bundle: .module)) { connect() }
                .buttonStyle(.borderedProminent)
                .disabled(!canSave)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }
    #endif

    // MARK: - iOS：保持系统 Form 结构

    #if !os(macOS)
    private var iOSBody: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(String(localized: "显示名称", bundle: .module), text: $displayName, prompt: Text(String(localized: "输入显示名称", bundle: .module)))
                        .textContentType(.organizationName)
                    TextField(String(localized: "服务器地址", bundle: .module), text: $serverURL, prompt: Text(String(localized: "输入服务器地址", bundle: .module)))
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                    TextField(String(localized: "用户名", bundle: .module), text: $username, prompt: Text(String(localized: "输入用户名", bundle: .module)))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("输入密码", text: $password)
                        .textContentType(.password)
                    TextField(String(localized: "外网地址（可选）", bundle: .module), text: $externalServerURL, prompt: Text(String(localized: "输入外网地址", bundle: .module)))
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                }
                Section {
                    HStack {
                        Button {
                            Task { await runTest() }
                        } label: {
                            if isTesting || isRequestingLocalNetworkAuthorization {
                                HStack(spacing: 6) {
                                    ProgressView().controlSize(.small)
                                    Text(isRequestingLocalNetworkAuthorization ? String(localized: "正在请求本地网络访问…", bundle: .module) : String(localized: "正在测试连接…", bundle: .module))
                                }
                            } else {
                                Text(String(localized: "测试连接", bundle: .module))
                            }
                        }
                        .disabled(isTesting || isRequestingLocalNetworkAuthorization || model.serverConnectionState.isConnecting)
                        if let testStatus {
                            Spacer()
                            statusLabel(testStatus)
                        }
                    }
                }
                Section(String(localized: "连接安全", bundle: .module)) {
                    Label(String(localized: "凭据安全存储在系统 Keychain 中。", bundle: .module), systemImage: "key")
                    Label(String(localized: "公网服务器建议使用 HTTPS。", bundle: .module), systemImage: "lock")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                if let localValidationError, testStatus == nil {
                    Section(String(localized: "需要处理", bundle: .module)) {
                        Label(localValidationError, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(theme.colorTokens.error.color)
                    }
                }
                if case let .connecting(stage) = model.serverConnectionState {
                    Section(String(localized: "连接进度", bundle: .module)) {
                        HStack { ProgressView(); Text(stage.title) }
                    }
                }
                if case let .failed(message) = model.serverConnectionState {
                    Section(String(localized: "连接失败", bundle: .module)) {
                        Text(message).lineLimit(nil).textSelection(.enabled)
                    }
                }
            }
            .navigationTitle(String(localized: "添加服务器", bundle: .module))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(model.serverConnectionState.isConnecting ? String(localized: "停止", bundle: .module) : String(localized: "取消", bundle: .module)) { cancelOrStop() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "保存", bundle: .module)) { connect() }
                        .disabled(model.serverConnectionState.isConnecting || isTesting)
                }
            }
        }
        .interactiveDismissDisabled(model.serverConnectionState.isConnecting)
    }
    #endif

    // MARK: - 共用：状态、校验与测试

    @ViewBuilder
    private func statusLabel(_ status: TestResultStatus) -> some View {
        switch status {
        case .success:
            Label(String(localized: "连接成功", bundle: .module), systemImage: "checkmark.circle.fill")
                .foregroundStyle(theme.colorTokens.success.color)
        case .authFailed:
            Label(String(localized: "用户名或密码错误", bundle: .module), systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(theme.colorTokens.error.color)
        case .unreachable:
            Label(String(localized: "无法连接服务器", bundle: .module), systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(theme.colorTokens.error.color)
        }
    }

    /// 连接测试结果 → 一行状态：认证类错误单列，其余一律视为「无法连接服务器」。
    private static func classifyFailure(_ message: String) -> TestResultStatus {
        let lower = message.lowercased()
        let authMarkers = ["用户名", "密码", "认证", "401"]
        if authMarkers.contains(where: { lower.contains($0) }) { return .authFailed }
        return .unreachable
    }

    private func cancelOrStop() {
        if model.serverConnectionState.isConnecting {
            connectionTask?.cancel()
            connectionTask = nil
        } else {
            password = ""
            dismiss()
        }
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
        testStatus = nil
        defer { isTesting = false }
        let rawURL = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: rawURL) else {
            testStatus = .unreachable
            return
        }
        do {
            try ServerURLPolicy.validate(url)
            guard await requestLocalNetworkAuthorizationIfNeeded(for: url) else {
                testStatus = .unreachable
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
            case .success: testStatus = .success
            case let .failure(message): testStatus = Self.classifyFailure(message)
            }
        } catch {
            testStatus = Self.classifyFailure(ConnectionErrorDescription.describe(error))
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

        localValidationError = "本地网络访问已被 macOS 拒绝。Auralis 会在首次连接时自动申请；若此前点过“不允许”，系统不会再次弹窗。请在“系统设置 → 隐私与安全性 → 本地网络”中打开“Auralis”后重试。"
        return false
#else
        return true
#endif
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
    @State private var endpointMode: AIEndpointMode = .chatCompletions
    @State private var isConfiguringAPIKey = false
    @State private var isTestingConnection = false
    @State private var connectionTestResult: ConnectionTestResult?

    private let credentialVault = KeychainCredentialVault()

    var body: some View {
        Form {
            Section(String(localized: "接口地址", bundle: .module)) {
                TextField("Base URL", text: $aiBaseURL, prompt: Text(AIConnectionSettings.defaultBaseURL))
#if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
#endif
                    .autocorrectionDisabled()
                Picker("接口协议", selection: $endpointMode) {
                    ForEach(AIEndpointMode.allCases) { mode in
                        VStack(alignment: .leading) {
                            Text(mode.title)
                            Text(mode.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .tag(mode)
                    }
                }
#if os(macOS)
                .pickerStyle(.menu)
#endif
                .onChange(of: endpointMode) { _, newValue in
                    if let apiPath = newValue.apiPath {
                        aiAPIPath = apiPath
                    }
                }
                if endpointMode == .custom {
                    TextField(String(localized: "API 路径", bundle: .module), text: $aiAPIPath, prompt: Text("/v1/chat/completions"))
#if os(iOS)
                        .textInputAutocapitalization(.never)
#endif
                        .autocorrectionDisabled()
                }
                TextField(String(localized: "模型", bundle: .module), text: $aiModel, prompt: Text(AIConnectionSettings.defaultModel))
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
                    Button(hasAPIKey ? String(localized: "更新 API Key", bundle: .module) : String(localized: "配置 API Key", bundle: .module)) { isConfiguringAPIKey = true }
                    #endif
                    if hasAPIKey {
                        Spacer()
                        Button(String(localized: "删除", bundle: .module), role: .destructive) {
                            Task {
                                try? await credentialVault.delete(id: AIConnectionSettings.credentialID)
                                hasAPIKey = false
                            }
                        }
                    }
                }
            }
            Section(String(localized: "高级设置", bundle: .module)) {
                Stepper(value: $aiMaxContextTokens, in: 4_096...1_000_000, step: 4_096) {
                    HStack {
                        Text(String(localized: "上下文窗口", bundle: .module))
                        Spacer()
                        Text("\(aiMaxContextTokens) token").foregroundStyle(theme.colorTokens.secondaryText.color)
                    }
                }
                Stepper(value: $aiMaxOutputTokens, in: 512...64_000, step: 512) {
                    HStack {
                        Text(String(localized: "单次输出上限", bundle: .module))
                        Spacer()
                        Text("\(aiMaxOutputTokens) token").foregroundStyle(theme.colorTokens.secondaryText.color)
                    }
                }
                Text(String(localized: "不同 OpenAI 兼容端点上下文窗口不同（OpenAI 128K/200K、DeepSeek 64K/128K、Ollama/LM Studio 取决于模型）。默认 256K / 16K 维持旧行为，可按实际模型修改。", bundle: .module))
                    .font(.caption)
                    .foregroundStyle(theme.colorTokens.secondaryText.color)
            }
            Section(String(localized: "连接测试", bundle: .module)) {
                HStack {
                    Button(action: testAIConnection) {
                        if isTestingConnection {
                            ProgressView().controlSize(.small)
                        } else {
                            Text(String(localized: "测试连接", bundle: .module))
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
                Text("""
支持 OpenAI Chat Completions、OpenAI Responses API，
以及 DeepSeek、通义千问、Kimi、Ollama、LM Studio
和兼容 OpenAI 协议的中转服务。
API Key 仅保存于系统 Keychain。
""")
                    .font(.caption)
                    .foregroundStyle(theme.colorTokens.secondaryText.color)
            }
        }
        .navigationTitle(String(localized: "OpenAI 兼容接口", bundle: .module))
        .onAppear {
            endpointMode = AIEndpointMode.infer(from: aiAPIPath)
        }
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
                        Button(String(localized: "完成", bundle: .module)) { dismiss() }
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
            Section(String(localized: "存储安全", bundle: .module)) {
                Label(String(localized: "仅写入系统 Keychain（本机、不同步）", bundle: .module), systemImage: "key.fill")
                if hasExistingKey {
                    Label(String(localized: "保存后将覆盖已存储的 Key", bundle: .module), systemImage: "arrow.triangle.2.circlepath")
                }
            }
            if let saveError {
                Section(String(localized: "需要处理", bundle: .module)) {
                    Label(saveError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(theme.colorTokens.error.color)
                }
            }
        }
        .navigationTitle(hasExistingKey ? String(localized: "更新 API Key", bundle: .module) : String(localized: "配置 API Key", bundle: .module))
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(String(localized: "存储到 Keychain", bundle: .module), action: save)
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
                        Button(String(localized: "取消", bundle: .module)) { dismiss() }
                    }
                }
        }
#if os(macOS)
        .frame(minWidth: 420, minHeight: 320)
#endif
    }
}