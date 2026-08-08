import AgentKit
import DesignSystem
import Domain
import SwiftUI
import ThemeEngine

/// AI 助手主界面：左侧会话列表，右侧结构化消息流。
///
/// 交互要点：
/// - 歌曲卡片点击即本地播放，不会二次调用大模型。
/// - 破坏性操作弹确认框，用户批准后才执行。
/// - 未配置或大模型不可用时，如实提示「AI 服务暂时不可用」，不谎称已切到本地模式；
///   本地搜索与播放不依赖大模型，照常可用。
struct AssistantView: View {
    @ObservedObject var model: AuralisAppModel
    let theme: BuiltInTheme

    @ObservedObject private var agent: AgentCoordinator
    @AppStorage("auralis.ai.enabled") private var aiEnabled = true
    @State private var showsSessionList = true
    @State private var showsSessionListSheet = false
    @State private var showsActionLog = false
    @State private var renamingSession: AgentSession?
    @State private var renameText = ""
    @State private var deletingSession: AgentSession?
    /// 输入框焦点：仅供本页用 @FocusState 管理，以便点击空白 / 拖动 / 发送时收起键盘。
    @FocusState private var assistantInputFocused: Bool

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    init(model: AuralisAppModel, theme: BuiltInTheme) {
        self.model = model
        self.theme = theme
        self.agent = model.agentCoordinator
    }

    private var settings: AIConnectionSettings { AIConnectionSettings() }
    /// 已启用 AI 且接口配置完整时走模型规划，否则本地规则模式。
    private var isLive: Bool { aiEnabled && settings.isComplete }

    var body: some View {
        VStack(spacing: 0) {
            if horizontalSizeClass == .compact {
                conversation
                    .frame(maxWidth: .infinity)
                .sheet(isPresented: $showsSessionListSheet) {
                    sessionSidebar
                        .presentationDetents([.medium, .large])
                        .presentationBackground(.ultraThinMaterial)
                }
            } else if showsSessionList {
                HStack(spacing: 0) {
                    sessionSidebar
                        .frame(width: 240)
                    Divider()
                    conversation
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                conversation
            }
        }
        .background(theme.colorTokens.background.color)
        .task { await agent.bootstrap() }
        .confirmationDialog(
            agent.pendingConfirmation?.title ?? "确认操作",
            isPresented: Binding(
                get: { agent.pendingConfirmation != nil },
                set: { if !$0 { agent.rejectConfirmation() } }
            ),
            titleVisibility: .visible
        ) {
            Button("确认执行", role: .destructive) { agent.approveConfirmation() }
            Button("取消", role: .cancel) { agent.rejectConfirmation() }
        } message: {
            if let pending = agent.pendingConfirmation {
                Text("\(pending.detail)\n此操作为\(permissionLabel(pending.permission))，请确认。")
            }
        }
        .alert("重命名会话", isPresented: Binding(
            get: { renamingSession != nil },
            set: { if !$0 { renamingSession = nil } }
        )) {
            TextField("会话名称", text: $renameText)
            Button("保存") {
                if let session = renamingSession {
                    Task { await agent.rename(session.id, to: renameText) }
                }
                renamingSession = nil
            }
            Button("取消", role: .cancel) { renamingSession = nil }
        }
        .alert("删除会话？", isPresented: Binding(
            get: { deletingSession != nil },
            set: { if !$0 { deletingSession = nil } }
        )) {
            Button("删除", role: .destructive) {
                if let session = deletingSession {
                    Task { await agent.delete(session.id) }
                }
                deletingSession = nil
            }
            Button("取消", role: .cancel) { deletingSession = nil }
        } message: {
            Text("会话及其消息会从本机删除，不影响音乐库与服务器数据。")
        }
        // 首次外发确认（B5）：consentGiven 未写入且本次请求要发往真实 Provider 时弹出。
        .alert(
            Text(agent.pendingConsent.map { "允许发送以下内容到「\($0.modelName)」？" } ?? "首次外发确认"),
            isPresented: Binding(
                get: { agent.pendingConsent != nil },
                set: { if !$0 { agent.denyConsent() } }
            ),
            presenting: agent.pendingConsent
        ) { _ in
            Button("允许一次") { agent.approveConsent(remember: false) }
            Button("允许并记住") { agent.approveConsent(remember: true) }
            Button("取消", role: .cancel) { agent.denyConsent() }
        } message: { consent in
            Text("\(consent.purpose)\n\(consent.fields.map { "· \($0)" }.joined(separator: "\n"))")
        }
        .sheet(isPresented: $showsActionLog) {
            ActionLogSheet(agent: agent, theme: theme)
        }
    }

    // MARK: - Session sidebar

    private var sessionSidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Text("会话").font(.headline)
                    .foregroundStyle(theme.colorTokens.primaryText.color)
                Spacer()
                Button {
                    Task { await agent.newSession() }
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .buttonStyle(HapticPlainButtonStyle())
                .help("新建会话")
            }
            .padding(.horizontal, AuralisSpacing.medium)
            .padding(.top, AuralisSpacing.medium)

            HStack(spacing: AuralisSpacing.xSmall) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(theme.colorTokens.secondaryText.color)
                TextField("搜索会话", text: $agent.sessionQuery)
                    .textFieldStyle(.plain)
            }
            .padding(AuralisSpacing.small)
            .background(theme.colorTokens.surface.color)
            .clipShape(RoundedRectangle(cornerRadius: AuralisRadius.small))
            .padding(.horizontal, AuralisSpacing.medium)
            .padding(.vertical, AuralisSpacing.small)

            Toggle("只看当前服务器", isOn: $agent.filtersByActiveServer)
                .toggleStyle(.switch)
                .font(.caption)
                .foregroundStyle(theme.colorTokens.secondaryText.color)
                .padding(.horizontal, AuralisSpacing.medium)

            List {
                ForEach(agent.sessions) { session in
                    sessionRow(session)
                }
            }
            .listStyle(.plain)

            Divider()
            Button {
                showsActionLog = true
            } label: {
                Label("操作记录（\(agent.actionRecords.count)）", systemImage: "list.bullet.rectangle")
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(HapticPlainButtonStyle())
            .padding(AuralisSpacing.medium)
        }
        .background(theme.colorTokens.elevated.color)
    }

    private func sessionRow(_ session: AgentSession) -> some View {
        Button {
            Task { await agent.activate(session.id) }
        } label: {
            HStack(spacing: AuralisSpacing.xSmall) {
                if session.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.caption2)
                        .foregroundStyle(theme.colorTokens.accent.color)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.title)
                        .font(.subheadline)
                        .lineLimit(1)
                        .foregroundStyle(theme.colorTokens.primaryText.color)
                    Text(session.summary ?? "\(session.messages.count) 条消息")
                        .font(.caption2)
                        .lineLimit(1)
                        .foregroundStyle(theme.colorTokens.secondaryText.color)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(HapticPlainButtonStyle())
        .listRowBackground(
            session.id == agent.activeSessionID
                ? theme.colorTokens.accent.color.opacity(0.16)
                : Color.clear
        )
        .contextMenu {
            Button(session.isPinned ? "取消置顶" : "置顶") {
                Task { await agent.togglePin(session.id) }
            }
            Button("重命名") {
                renameText = session.title
                renamingSession = session
            }
            Button("清空消息") {
                Task { await agent.clearMessages(session.id) }
            }
            Divider()
            Button("删除", role: .destructive) { deletingSession = session }
        }
    }

    // MARK: - Conversation

    /// 会话区：标题 + 消息流。输入框通过 `.safeAreaInset(edge: .bottom)` 浮在底部，
    /// 与迷你播放条处于同一屏幕位置（主菜单栏之上），列表滚动区自动避让，
    /// 键盘弹出时随之上移，不再被遮挡、也不与主菜单栏重叠。
    private var conversation: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: AuralisSpacing.large) {
                        if agent.messages.isEmpty { emptyState }
                        ForEach(agent.messages) { message in
                            messageRow(message).id(message.id)
                        }
                        if agent.isRunning { runningIndicator }
                    }
                    .padding(AuralisSpacing.large)
                    // 点击聊天空白区域收起键盘（不影响卡片自身的点按）。
                    .onTapGesture { assistantInputFocused = false }
                }
                // 向下拖动聊天列表时交互式收起键盘。
                .scrollDismissesKeyboard(.immediately)
                .onChange(of: agent.messages.count) { _, _ in
                    if let last = agent.messages.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #if os(iOS)
        // 输入框作为底部安全区浮层：只有它响应键盘安全区（随键盘上移），
        // 主菜单栏由根 Dock 覆盖层渲染并忽略键盘（固定在屏幕底部、被键盘遮挡）。
        // 浮层内容只含「输入框 + 8pt 间距」这一固定 64pt 高度，两态 frame 完全一致：
        // 键盘关闭时输入框底边停在距安全区底 8pt 处（即主菜单栏上方 8pt）；
        // 键盘打开时输入框底边停在距键盘顶 8pt 处。输入框宽度/高度/圆角始终不变。
        .safeAreaInset(edge: .bottom, spacing: 0) {
            DockAssistantInputBar(model: model, theme: theme, focus: $assistantInputFocused)
                // 键盘关闭时：主菜单栏是独立的底部 overlay（忽略键盘），会覆盖在屏幕最底，
                // 这里额外预留主菜单栏真实占用高度，让输入框停在它上方 8pt（dockSpacing）。
                // 键盘打开时：主菜单栏已被键盘遮住，输入框随键盘上移，只需保留很小间隙，
                // 避免「键盘与输入框之间一大段空白」。
                .padding(
                    .bottom,
                    assistantInputFocused
                        ? AuralisSpacing.small
                        : (dockSpacing + bottomBarHeight + dockBottomPadding)
                )
        }
        #else
        // macOS 没有底部 Dock，输入框作为本页底部安全区浮层。
        .safeAreaInset(edge: .bottom, spacing: 0) {
            inputBar
        }
        #endif
    }

    private var header: some View {
        HStack(spacing: AuralisSpacing.medium) {
            // 一行：模型名称 + 状态，与右侧按钮平齐。
            if isLive {
                Label(settings.model, systemImage: "checkmark.seal.fill")
                    .font(.subheadline)
                    .foregroundStyle(theme.colorTokens.success.color)
                    .lineLimit(1)
            } else {
                Label("未配置模型接口", systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(theme.colorTokens.warning.color)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if !isLive {
                Button { model.selectedSection = .settings } label: {
                    Label("配置", systemImage: "gearshape")
                }
                .buttonStyle(HapticBorderedButtonStyle())
                .controlSize(.small)
            }
            sessionListButton
        }
        .padding(AuralisSpacing.large)
        .accessibilityElement(children: .contain)
    }

    private var sessionListButton: some View {
        Button {
            if horizontalSizeClass == .compact {
                showsSessionListSheet = true
            } else {
                withAnimation { showsSessionList.toggle() }
            }
        } label: {
            Image(systemName: "sidebar.leading")
        }
        .buttonStyle(HapticPlainButtonStyle())
        .accessibilityLabel("会话列表")
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: AuralisSpacing.medium) {
            Text("试试这样说").font(.headline)
                .foregroundStyle(theme.colorTokens.primaryText.color)
            FlowChips(
                titles: ["播放周杰伦", "找几首适合深夜的歌", "我的收藏有哪些", "把当前这首加入队列", "推荐和现在这首相似的"],
                theme: theme
            ) { model.assistantDraft = $0 }
            if !model.catalog.isConnected {
                Label("尚未连接服务器，本地目录为空", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(theme.colorTokens.warning.color)
            }
        }
    }

    private var runningIndicator: some View {
        HStack(spacing: AuralisSpacing.small) {
            ProgressView().controlSize(.small)
            // 显示任务管理器中的当前阶段（如「正在理解请求」「执行 playTrack」），
            // 不展示 tool_call JSON / 凭据 / 原始服务器响应。
            Text(agent.activeTask?.currentStep ?? "正在处理…").font(.caption)
                .foregroundStyle(theme.colorTokens.secondaryText.color)
            Button("停止") { agent.cancel() }
                .buttonStyle(HapticBorderedButtonStyle())
                .controlSize(.small)
        }
    }

    @ViewBuilder
    private func messageRow(_ message: AgentChatMessage) -> some View {
        let isUser = message.role == .user
        VStack(alignment: isUser ? .trailing : .leading, spacing: AuralisSpacing.small) {
            ForEach(Array(message.messages.enumerated()), id: \.offset) { _, item in
                messageBody(item, isUser: isUser)
            }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    }

    @ViewBuilder
    private func messageBody(_ item: AgentMessage, isUser: Bool) -> some View {
        switch item {
        case let .text(text):
            Text(text)
                .padding(AuralisSpacing.medium)
                .foregroundStyle(theme.colorTokens.primaryText.color)
                .background(isUser ? theme.colorTokens.accent.color.opacity(0.22) : theme.colorTokens.elevated.color)
                .clipShape(RoundedRectangle(cornerRadius: AuralisRadius.medium))
                .frame(maxWidth: 560, alignment: isUser ? .trailing : .leading)
                .textSelection(.enabled)

        case let .trackCards(cards):
            TrackCardList(cards: cards, agent: agent, theme: theme)

        case let .albumCards(cards):
            VStack(alignment: .leading, spacing: AuralisSpacing.xSmall) {
                ForEach(cards) { card in
                    HStack {
                        Image(systemName: "square.stack")
                            .foregroundStyle(theme.colorTokens.accent.color)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(card.title).font(.subheadline)
                                .foregroundStyle(theme.colorTokens.primaryText.color)
                            Text(card.artistName).font(.caption2)
                                .foregroundStyle(theme.colorTokens.secondaryText.color)
                        }
                        Spacer()
                    }
                    .padding(AuralisSpacing.small)
                    .background(theme.colorTokens.elevated.color)
                    .clipShape(RoundedRectangle(cornerRadius: AuralisRadius.small))
                }
            }
            .frame(maxWidth: 560, alignment: .leading)

        case let .playlistProposal(name, tracks):
            VStack(alignment: .leading, spacing: AuralisSpacing.small) {
                HStack {
                    Label(name, systemImage: "music.note.list")
                        .font(.headline)
                        .foregroundStyle(theme.colorTokens.primaryText.color)
                    Spacer()
                    Button("全部播放") { agent.playAll(cards: tracks) }
                        .buttonStyle(HapticProminentButtonStyle())
                        .controlSize(.small)
                }
                TrackCardList(cards: tracks, agent: agent, theme: theme)
            }
            .padding(AuralisSpacing.medium)
            .background(theme.colorTokens.elevated.color)
            .clipShape(RoundedRectangle(cornerRadius: AuralisRadius.medium))
            .frame(maxWidth: 560, alignment: .leading)

        case let .actionPreview(title, detail):
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.bold())
                    .foregroundStyle(theme.colorTokens.primaryText.color)
                Text(detail).font(.caption)
                    .foregroundStyle(theme.colorTokens.secondaryText.color)
            }
            .padding(AuralisSpacing.medium)
            .background(theme.colorTokens.surface.color)
            .clipShape(RoundedRectangle(cornerRadius: AuralisRadius.small))

        case let .toolProgress(step):
            Label(step, systemImage: "gearshape.arrow.trianglehead.2.clockwise.rotate.90")
                .font(.caption2)
                .foregroundStyle(theme.colorTokens.secondaryText.color)

        case let .error(text):
            Label(text, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(theme.colorTokens.error.color)

        case let .confirmation(pending):
            Label("等待确认：\(pending.title)", systemImage: "questionmark.circle")
                .font(.caption)
                .foregroundStyle(theme.colorTokens.warning.color)
        }
    }

    /// 输入框（macOS 版）：原生 macOS 样式，固定在底部安全区。
    /// iOS 版的输入框由底部 Dock 统一渲染（见 AuralisRootView 的 DockAssistantInputBar），
    /// 避免嵌套 safeAreaInset 与 Dock 主菜单栏重叠。
    #if os(macOS)
    private var inputBar: some View {
        HStack(alignment: .center, spacing: AuralisSpacing.medium) {
            Image(systemName: "sparkles")
                .foregroundStyle(theme.colorTokens.accent.color)
                .frame(width: 22, height: 22)
            TextField("描述你想听的音乐，或让我帮你操作", text: $model.assistantDraft)
                .textFieldStyle(.roundedBorder)
                .focused($assistantInputFocused)
                .onSubmit { model.sendAssistantMessage(); assistantInputFocused = false }
            Button {
                if model.assistantIsRunning { model.cancelAssistant() } else { model.sendAssistantMessage(); assistantInputFocused = false }
            } label: {
                Image(systemName: model.assistantIsRunning ? "stop.circle.fill" : "arrow.up.circle.fill")
                    .font(.title2)
            }
            .buttonStyle(HapticPlainButtonStyle())
            .accessibilityLabel(model.assistantIsRunning ? "停止" : "发送")
            .frame(width: 32, height: 32)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(theme.colorTokens.surface.color)
        .clipShape(RoundedRectangle(cornerRadius: AuralisRadius.medium, style: .continuous))
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }
    #endif

    private func permissionLabel(_ permission: ToolPermission) -> String {
        switch permission {
        case .readOnly: "只读操作"
        case .reversible: "可撤销操作"
        case .destructive: "破坏性操作（不可自动恢复）"
        }
    }
}

// MARK: - Track cards

/// 结构化歌曲卡片列表。每张卡片都带真实 GlobalTrackID，点击即本地播放。
private struct TrackCardList: View {
    let cards: [TrackCard]
    @ObservedObject var agent: AgentCoordinator
    let theme: BuiltInTheme

    var body: some View {
        VStack(spacing: AuralisSpacing.xSmall) {
            ForEach(cards) { card in
                TrackCardRow(card: card, agent: agent, theme: theme)
            }
        }
        .frame(maxWidth: 560, alignment: .leading)
    }
}

private struct TrackCardRow: View {
    let card: TrackCard
    @ObservedObject var agent: AgentCoordinator
    let theme: BuiltInTheme
    @State private var showsFeedback = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: AuralisSpacing.small) {
                Button { agent.play(card: card) } label: {
                    Image(systemName: "play.circle.fill")
                        .font(.title3)
                        .foregroundStyle(theme.colorTokens.accent.color)
                }
                .buttonStyle(HapticPlainButtonStyle())
                .help("播放")

                VStack(alignment: .leading, spacing: 1) {
                    Text(card.title)
                        .font(.subheadline)
                        .lineLimit(1)
                        .foregroundStyle(theme.colorTokens.primaryText.color)
                    Text("\(card.artistName) · \(card.albumTitle)")
                        .font(.caption2)
                        .lineLimit(1)
                        .foregroundStyle(theme.colorTokens.secondaryText.color)
                }
                Spacer(minLength: AuralisSpacing.small)

                Text(Self.format(card.duration))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(theme.colorTokens.secondaryText.color)

                Button { agent.toggleFavorite(card: card) } label: {
                    Image(systemName: card.isFavorite ? "heart.fill" : "heart")
                        .foregroundStyle(card.isFavorite ? theme.colorTokens.error.color : theme.colorTokens.secondaryText.color)
                }
                .buttonStyle(HapticPlainButtonStyle())
                .help(card.isFavorite ? "取消喜爱" : "喜爱")

                Menu {
                    Button("加入队列") { agent.queue(card: card) }
                    Divider()
                    Section("推荐反馈") {
                        ForEach(RecommendationFeedback.allCases) { kind in
                            Button(kind.label) {
                                Task { await agent.sendFeedback(kind, for: card) }
                            }
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(theme.colorTokens.secondaryText.color)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .padding(AuralisSpacing.small)
        }
        .background(theme.colorTokens.elevated.color)
        .clipShape(RoundedRectangle(cornerRadius: AuralisRadius.small))
        .contentShape(Rectangle())
        // 整行点击也直接播放，无需再走大模型。
        .onTapGesture { agent.play(card: card) }
    }

    private static func format(_ duration: TimeInterval) -> String {
        guard duration > 0 else { return "--:--" }
        let total = Int(duration.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - Action log

private struct ActionLogSheet: View {
    @ObservedObject var agent: AgentCoordinator
    let theme: BuiltInTheme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("操作记录").font(.headline)
                Spacer()
                Button("清空") { Task { await agent.clearActionLog() } }
                    .buttonStyle(HapticBorderedButtonStyle())
                Button("完成") { dismiss() }
                    .buttonStyle(HapticProminentButtonStyle())
            }
            .padding(AuralisSpacing.medium)
            Divider()
            if agent.actionRecords.isEmpty {
                Spacer()
                Text("暂无修改型操作").foregroundStyle(theme.colorTokens.secondaryText.color)
                Spacer()
            } else {
                List(agent.actionRecords) { record in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(record.summary)
                                .font(.subheadline)
                                .strikethrough(record.undone)
                            Text("\(record.toolName) · \(record.timestamp.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption2)
                                .foregroundStyle(theme.colorTokens.secondaryText.color)
                        }
                        Spacer()
                        if record.undone {
                            Text("已撤销").font(.caption2)
                                .foregroundStyle(theme.colorTokens.secondaryText.color)
                        } else if record.permission == .reversible {
                            Button("撤销") { Task { await agent.undo(record) } }
                                .buttonStyle(HapticBorderedButtonStyle())
                                .controlSize(.small)
                        } else {
                            Text("不可撤销").font(.caption2)
                                .foregroundStyle(theme.colorTokens.warning.color)
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .frame(minWidth: 420, minHeight: 360)
        .task { await agent.refreshActionRecords() }
    }
}

// MARK: - Chips

private struct FlowChips: View {
    let titles: [String]
    let theme: BuiltInTheme
    let action: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: AuralisSpacing.small) {
                ForEach(titles, id: \.self) { title in
                    Button(title) { action(title) }
                        .buttonStyle(HapticBorderedButtonStyle())
                        .controlSize(.small)
                }
            }
        }
    }
}
