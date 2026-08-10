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
                .frame(minWidth: 520, minHeight: 420)
        }
        .alert("删除服务器？", isPresented: Binding(
            get: { serverToRemove != nil },
            set: { if !$0 { serverToRemove = nil } }
        )) {
            Button("删除", role: .destructive) {
                if let server = serverToRemove {
                    Task {
                        await model.catalogCoordinator.purgeLocalData(serverID: server.id)
                        await model.removeServerLocally(serverID: server.id)
                    }
                }
                serverToRemove = nil
            }
            Button("取消", role: .cancel) { serverToRemove = nil }
        } message: {
            Text("将删除本机保存的登录凭据、离线目录与缓存；服务器上的音乐、歌单与收藏不会被删除。")
        }
    }

    private var header: some View {
        HStack(spacing: AuralisSpacing.medium) {
            Text("服务器").font(.title2.bold())
                .foregroundStyle(theme.colorTokens.primaryText.color)
            Spacer()
            Button {
                isAddingServer = true
            } label: {
                Label("添加 OpenSubsonic 服务器", systemImage: "plus.circle.fill")
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
                localNetworkAccess
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

    /// 本地网络授权由 macOS 管理；这里说明触发时机，并提供被拒绝后的直达入口。
    private var localNetworkAccess: some View {
        HStack(alignment: .top, spacing: AuralisSpacing.medium) {
            Image(systemName: "network.badge.shield.half.filled")
                .font(.title3)
                .foregroundStyle(theme.colorTokens.accent.color)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text("局域网访问")
                    .font(.headline)
                    .foregroundStyle(theme.colorTokens.primaryText.color)
                Text("首次连接内网服务器时，macOS 会显示“本地网络”授权提示。若之前选择了不允许，可在系统设置中重新开启。")
                    .font(.caption)
                    .foregroundStyle(theme.colorTokens.secondaryText.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button("打开设置") {
                PlatformLocalNetworkSettings.open()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(AuralisSpacing.medium)
        .background(theme.colorTokens.accent.color.opacity(0.08), in: RoundedRectangle(cornerRadius: AuralisRadius.medium, style: .continuous))
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: AuralisSpacing.small) {
            Text("服务器摘要").font(.headline)
                .foregroundStyle(theme.colorTokens.primaryText.color)
            switch model.serverConnectionState {
            case .idle:
                LabeledContent("当前资料库", value: "未连接服务器")
                LabeledContent("状态", value: "尚未添加服务器")
            case let .connecting(stage):
                HStack { ProgressView().controlSize(.small); Text(stage.title) }
            case let .connected(account, serverType, serverVersion, trackCount):
                LabeledContent("服务器名称", value: account.displayName)
                if let url = account.baseURL {
                    LabeledContent("地址", value: Self.maskedURL(url))
                }
                LabeledContent("状态", value: "在线")
                if let serverType { LabeledContent("服务器类型", value: serverType) }
                if let serverVersion { LabeledContent("版本 / API", value: serverVersion) }
                LabeledContent("已同步", value: "\(trackCount) 首歌曲")
            case let .failed(message):
                LabeledContent("状态", value: "连接失败")
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
                    Text("连接失败").font(.headline)
                        .foregroundStyle(theme.colorTokens.error.color)
                    Spacer()
                    Button(showErrorDetails ? "收起详情" : "详情") { showErrorDetails.toggle() }
                        .buttonStyle(.link)
                }
                Text(showErrorDetails ? message : String(message.prefix(60)) + (message.count > 60 ? "…" : ""))
                    .font(.caption)
                    .foregroundStyle(theme.colorTokens.secondaryText.color)
                if message.contains("本地网络") {
                    Button("打开本地网络设置") {
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
            Button("重新连接") { isAddingServer = true }
                .disabled(model.serverConnectionState.isConnecting)
            Button("检查服务器") {
                Task { _ = await model.testActiveServerConnection() }
            }
            .disabled(!model.catalog.isConnected)
            Button("编辑服务器") { isAddingServer = true }
            if case let .failed(message) = model.serverConnectionState {
                Button("复制错误详情") {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(message, forType: .string)
                }
            }
            if let active = model.catalog.activeAccount {
                Button("删除服务器", role: .destructive) { serverToRemove = active }
            }
        }
        .buttonStyle(.bordered)
    }

    private var syncArea: some View {
        VStack(alignment: .leading, spacing: AuralisSpacing.small) {
            Text("音乐库同步").font(.headline)
                .foregroundStyle(theme.colorTokens.primaryText.color)
            if let serverID = model.catalog.activeServerID {
                Button("立即同步") { model.catalogCoordinator.manualRefresh(serverID: serverID) }
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
