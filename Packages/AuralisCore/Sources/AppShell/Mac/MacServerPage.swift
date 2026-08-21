#if os(macOS)
import Application
import DesignSystem
import Domain
import SwiftUI
import ThemeEngine

/// macOS 服务器设置页：清晰摘要 + 错误区 + 主按钮 + 服务器列表/详情。
struct MacServerPage: View {
    @ObservedObject var model: AuralisAppModel
    let theme: BuiltInTheme
    @State private var isAddingServer = false
    @State private var isEditing = false
    @State private var showErrorDetails = false
    @State private var savedServers: [ServerAccount] = []
    @State private var serverToRemove: ServerAccount?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(alignment: .top, spacing: 0) {
                if savedServers.count > 1 {
                    serverList
                        .frame(width: 240)
                    Divider()
                }
                serverDetail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(theme.colorTokens.background.color)
        .task { await reloadServers() }
        .sheet(isPresented: $isAddingServer) {
            ServerConnectionSheet(model: model, theme: theme)
                .frame(minWidth: 540, minHeight: 400)
        }
        .alert(String(localized: "删除服务器？", bundle: .module), isPresented: Binding(
            get: { serverToRemove != nil },
            set: { if !$0 { serverToRemove = nil } }
        )) {
            Button(String(localized: "删除", bundle: .module), role: .destructive) {
                if let server = serverToRemove {
                    Task {
                        await model.catalogCoordinator.purgeLocalData(serverID: server.id)
                        await model.removeServerLocally(serverID: server.id)
                    }
                }
                serverToRemove = nil
            }
            Button(String(localized: "取消", bundle: .module), role: .cancel) { serverToRemove = nil }
        } message: {
            Text(String(localized: "将删除本机保存的登录凭据、离线目录与缓存；服务器上的音乐、歌单与收藏不会被删除。", bundle: .module))
        }
    }

    private var header: some View {
        HStack(spacing: AuralisSpacing.medium) {
            Text(String(localized: "服务器", bundle: .module)).font(.title2.bold())
                .foregroundStyle(theme.colorTokens.primaryText.color)
            Spacer()
            Button {
                isAddingServer = true
            } label: {
                Label(String(localized: "添加 OpenSubsonic 服务器", bundle: .module), systemImage: "plus.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(.horizontal, AuralisSpacing.large)
        .padding(.vertical, AuralisSpacing.medium)
    }

    private var serverList: some View {
        List(savedServers) { server in
            Button {
                Task { await model.switchServer(serverID: server.id) }
            } label: {
                HStack {
                    Text(server.displayName)
                        .fontWeight(model.catalog.activeServerID == server.id ? .semibold : .regular)
                        .lineLimit(1)
                    Spacer()
                    if model.catalog.activeServerID == server.id {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(theme.colorTokens.accent.color)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .listStyle(.sidebar)
    }

    private var serverDetail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AuralisSpacing.large) {
                summary
                errorArea
                actions
                if model.catalog.isConnected {
                    Divider()
                    syncArea
                }
            }
            .padding(AuralisSpacing.large)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: AuralisSpacing.small) {
            Text(String(localized: "服务器摘要", bundle: .module)).font(.headline)
                .foregroundStyle(theme.colorTokens.primaryText.color)
            switch model.serverConnectionState {
            case .idle:
                LabeledContent(String(localized: "当前资料库", bundle: .module), value: String(localized: "未连接服务器", bundle: .module))
                LabeledContent(String(localized: "状态", bundle: .module), value: String(localized: "尚未添加服务器", bundle: .module))
            case let .connecting(stage):
                HStack { ProgressView().controlSize(.small); Text(stage.title) }
            case let .connected(account, serverType, serverVersion, trackCount):
                LabeledContent(String(localized: "服务器名称", bundle: .module), value: account.displayName)
                if let url = account.baseURL {
                    LabeledContent(String(localized: "地址", bundle: .module), value: Self.maskedURL(url))
                }
                LabeledContent(String(localized: "状态", bundle: .module), value: String(localized: "在线", bundle: .module))
                if let serverType { LabeledContent(String(localized: "服务器类型", bundle: .module), value: serverType) }
                if let serverVersion { LabeledContent(String(localized: "版本 / API", bundle: .module), value: serverVersion) }
                LabeledContent(String(localized: "已同步", bundle: .module), value: String(localized: "\(trackCount) 首歌曲", bundle: .module))
            case let .failed(message):
                LabeledContent(String(localized: "状态", bundle: .module), value: String(localized: "连接失败", bundle: .module))
                Text(message).font(.caption)
                    .foregroundStyle(theme.colorTokens.error.color)
            }
        }
        .padding(AuralisSpacing.large)
        .background(theme.colorTokens.surface.color.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: AuralisRadius.medium, style: .continuous))
    }

    @ViewBuilder
    private var errorArea: some View {
        if case let .failed(message) = model.serverConnectionState {
            VStack(alignment: .leading, spacing: AuralisSpacing.small) {
                HStack(spacing: AuralisSpacing.small) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(theme.colorTokens.error.color)
                    Text(String(localized: "连接失败", bundle: .module)).font(.headline)
                        .foregroundStyle(theme.colorTokens.error.color)
                    Spacer()
                    Button(showErrorDetails ? String(localized: "收起详情", bundle: .module) : String(localized: "详情", bundle: .module)) { showErrorDetails.toggle() }
                        .buttonStyle(.link)
                }
                Text(showErrorDetails ? message : String(message.prefix(60)) + (message.count > 60 ? "…" : ""))
                    .font(.caption)
                    .foregroundStyle(theme.colorTokens.secondaryText.color)
                if message.contains("本地网络") {
                    Button(String(localized: "打开本地网络设置", bundle: .module)) {
                        PlatformLocalNetworkSettings.open()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding(AuralisSpacing.large)
            .background(theme.colorTokens.error.color.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: AuralisRadius.medium, style: .continuous))
        }
    }

    private var actions: some View {
        HStack(spacing: AuralisSpacing.medium) {
            Button(String(localized: "重新连接", bundle: .module)) { isAddingServer = true }
                .disabled(model.serverConnectionState.isConnecting)
            Button(String(localized: "检查服务器", bundle: .module)) {
                Task { _ = await model.testActiveServerConnection() }
            }
            .disabled(!model.catalog.isConnected)
            Button(String(localized: "编辑服务器", bundle: .module)) { isAddingServer = true }
            if case let .failed(message) = model.serverConnectionState {
                Button(String(localized: "复制错误详情", bundle: .module)) {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(message, forType: .string)
                }
            }
            if let active = model.catalog.activeAccount {
                Button(String(localized: "删除服务器", bundle: .module), role: .destructive) { serverToRemove = active }
            }
        }
        .buttonStyle(.bordered)
    }

    private var syncArea: some View {
        VStack(alignment: .leading, spacing: AuralisSpacing.small) {
            Text(String(localized: "音乐库同步", bundle: .module)).font(.headline)
                .foregroundStyle(theme.colorTokens.primaryText.color)
            if let serverID = model.catalog.activeServerID {
                Button(String(localized: "立即同步", bundle: .module)) { model.catalogCoordinator.manualRefresh(serverID: serverID) }
                    .buttonStyle(.bordered)
            }
        }
    }

    private func reloadServers() async {
        savedServers = (try? await model.catalogCoordinator.store.listServers()) ?? []
    }

    /// 脱敏显示服务器地址：只显示 scheme + host + port，不含路径参数与认证信息。
    private static func maskedURL(_ url: URL) -> String {
        var parts = ""
        if let scheme = url.scheme { parts += scheme + "://" }
        if let host = url.host { parts += host }
        if let port = url.port { parts += ":\(port)" }
        return parts.isEmpty ? url.absoluteString : parts
    }
}
#endif
