import AgentKit
import DesignSystem
import Domain
import SwiftUI
import ThemeEngine

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

private struct AssistantConversationViewportBottomPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = .zero

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct AssistantConversationContentBottomPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = .zero

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// AI 输入栏与根 Dock 共享端点进度，但不共享安全区所有权。
/// 进度必须被 clamp，保证异常输入也不会把输入栏推入 Dock 之外。
struct AssistantDockInputLayout {
    static func horizontalPadding(
        focused: Bool,
        metrics: BottomChromeMetrics,
        collapseProgress: CGFloat
    ) -> CGFloat {
        guard !focused else { return 0 }
        return (metrics.dockHeight + metrics.spacing) * normalized(collapseProgress)
    }

    static func bottomPadding(
        focused: Bool,
        metrics: BottomChromeMetrics,
        collapseProgress: CGFloat,
        focusedBottomPadding: CGFloat = AuralisSpacing.small
    ) -> CGFloat {
        guard !focused else { return focusedBottomPadding }
        return metrics.bottomPadding
            + (metrics.spacing + metrics.dockHeight) * (1 - normalized(collapseProgress))
    }

    private static func normalized(_ progress: CGFloat) -> CGFloat {
        min(max(progress, 0), 1)
    }
}

private enum AssistantSheet: String, Identifiable {
    case sessions
    case librarySearch
    case actionLog

    var id: String { rawValue }
}

/// AI 助手主界面：左侧会话列表，右侧结构化消息流。
///
/// 交互要点：
/// - 歌曲卡片点击即本地播放，不会二次调用大模型。
/// - 破坏性操作弹确认框，用户批准后才执行。
/// - 未配置或大模型不可用时，如实提示「AI 服务暂时不可用」，不谎称已切到本地模式；
///   本地搜索与播放不依赖大模型，照常可用。
struct AssistantView: View {
    /// 末尾锚点必须是独立视图：最后一条消息在流式输出时高度会变化，而其 id 不变。
    /// 用稳定的底部锚点滚动，才能始终贴住最新工具进度和回复结尾。
    private static let conversationEndID = "assistant-conversation-end"
    private static let conversationScrollCoordinateSpace = "assistant-conversation-scroll"
    /// 距底部不超过此距离时，新的流式内容才会自动跟随；用户上翻阅读时不抢回滚动位置。
    private static let autoFollowThreshold: CGFloat = 80

    @ObservedObject var model: AuralisAppModel
    let theme: BuiltInTheme

    @ObservedObject private var agent: AgentCoordinator
    @AppStorage("auralis.ai.enabled") private var aiEnabled = true
    @State private var presentedSheet: AssistantSheet?
    @State private var renamingSession: AgentSession?
    @State private var renameText = ""
    @State private var deletingSession: AgentSession?
    /// 会话批量管理模式：多选后统一删除 / 归档。
    @State private var isBatchManaging = false
    @State private var selectedSessionIDs: Set<UUID> = []
    @State private var confirmBatchDelete = false
    @State private var isFollowingConversationOutput = true
    @State private var conversationViewportBottom: CGFloat = .zero
    @State private var conversationContentBottom: CGFloat = .zero
    /// 输入框焦点：仅供本页用 @FocusState 管理，以便点击空白 / 拖动 / 发送时收起键盘。
    @FocusState private var assistantInputFocused: Bool

    @Environment(\.bottomDockScrollCoordinator) private var bottomDockScroll: BottomDockScrollCoordinator?
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
            // iPhone 与 iPad 统一：会话列表始终以 sheet 呈现（不再有 regular-width 的
            // 桌面式 Sidebar 分支）；宽屏只通过可用宽度约束布局，不切换 UI 架构。
            conversation
                .frame(maxWidth: .infinity)
            .sheet(item: $presentedSheet) { sheet in
                switch sheet {
                case .sessions:
                    #if os(macOS)
                    sessionSidebar
                        // macOS sheet 会按内容的理想尺寸计算；不给明确高度时，List
                        // 会在标题、搜索框和底部操作记录之间被压缩到不可见。
                        .frame(
                            minWidth: 360,
                            idealWidth: 380,
                            minHeight: 500,
                            idealHeight: 600
                        )
                    #else
                    sessionSidebar
                        .presentationDetents([.medium, .large])
                        .presentationBackground(.ultraThinMaterial)
                    #endif
                case .librarySearch:
                    NavigationStack {
                        SearchView(model: model, theme: theme)
                            .navigationTitle(String(localized: "搜索音乐库", bundle: .module))
                            #if os(iOS)
                            .navigationBarTitleDisplayMode(.inline)
                            #endif
                    }
                case .actionLog:
                    ActionLogSheet(agent: agent, theme: theme)
                }
            }
        }
        .background {
            #if os(macOS)
            // macOS 的 AI 助手也是 Auralis 内容页；不能落回系统 under-page 背景，
            // 否则切换主题时会与资料库、服务器设置出现两套色板。
            theme.colorTokens.background.color
            #else
            theme.colorTokens.background.color
            #endif
        }
        .alert(String(localized: "重命名会话", bundle: .module), isPresented: Binding(
            get: { renamingSession != nil },
            set: { if !$0 { renamingSession = nil } }
        )) {
            TextField(String(localized: "会话名称", bundle: .module), text: $renameText)
            Button(String(localized: "保存", bundle: .module)) {
                if let session = renamingSession {
                    Task { await agent.rename(session.id, to: renameText) }
                }
                renamingSession = nil
            }
            Button(String(localized: "取消", bundle: .module), role: .cancel) { renamingSession = nil }
        }
        .alert(String(localized: "删除会话？", bundle: .module), isPresented: Binding(
            get: { deletingSession != nil },
            set: { if !$0 { deletingSession = nil } }
        )) {
            Button(String(localized: "删除", bundle: .module), role: .destructive) {
                if let session = deletingSession {
                    Task { await agent.delete(session.id) }
                }
                deletingSession = nil
            }
            Button(String(localized: "取消", bundle: .module), role: .cancel) { deletingSession = nil }
        } message: {
            Text(String(localized: "会话及其消息会从本机删除，不影响音乐库与服务器数据。", bundle: .module))
        }
        // 首次外发确认（B5）：consentGiven 未写入且本次请求要发往真实 Provider 时弹出。
        .alert(
            Text(agent.pendingConsent.map { String(localized: "允许发送以下内容到「\($0.modelName)」？", bundle: .module) } ?? String(localized: "首次外发确认", bundle: .module)),
            isPresented: Binding(
                get: { agent.pendingConsent != nil },
                // SwiftUI 可能在 view update / alert reconciliation 阶段回调 setter；
                // 若在此同步 publish ObservableObject 会触发
                // "Publishing changes from within view updates"。
                // 将 denyConsent 延迟到当前 transaction 结束后的下一 main runloop：
                // 还要绑定 request id，避免旧 alert 的迟到 dismiss 误拒绝新请求。
                set: { isPresented in
                    guard !isPresented, let consentID = agent.pendingConsent?.id else { return }
                    DispatchQueue.main.async {
                        guard agent.pendingConsent?.id == consentID else { return }
                        agent.denyConsent()
                    }
                }
            ),
            presenting: agent.pendingConsent
        ) { _ in
            Button(String(localized: "允许一次", bundle: .module)) { agent.approveConsent(remember: false) }
            Button(String(localized: "允许并记住", bundle: .module)) { agent.approveConsent(remember: true) }
            Button(String(localized: "取消", bundle: .module), role: .cancel) { agent.denyConsent() }
        } message: { consent in
            Text("\(consent.purpose)\n\(consent.fields.map { "· \($0)" }.joined(separator: "\n"))")
        }
        // 运行时确认：只有 descriptor 明确标记为 destructive/需显式批准的工具
        // 才通过 PendingConfirmation 挂起；模型文本不会自行替代可见确认。
        .alert(
            Text(agent.pendingOperationConfirmation?.title ?? String(localized: "确认操作", bundle: .module)),
            isPresented: Binding(
                get: { agent.pendingOperationConfirmation != nil },
                // 与 pendingConsent 相同：dismiss 的 setter 延迟到下一 main runloop。
                // resolveOperationConfirmation 幂等（continuation 已消费则仅清状态），
                // 绑定 confirmation id 后，approve 后的迟到 dismiss 以及旧 alert
                // 的迟到回调都不会误伤新的确认。
                set: { isPresented in
                    guard !isPresented,
                          let confirmationID = agent.pendingOperationConfirmation?.id else { return }
                    DispatchQueue.main.async {
                        guard agent.pendingOperationConfirmation?.id == confirmationID else { return }
                        agent.denyOperationConfirmation()
                    }
                }
            ),
            presenting: agent.pendingOperationConfirmation
        ) { _ in
            if agent.pendingOperationConfirmation?.permission == .destructive {
                Button(String(localized: "批准并执行", bundle: .module), role: .destructive) {
                    agent.approveOperationConfirmation()
                }
            } else {
                Button(String(localized: "批准并执行", bundle: .module)) {
                    agent.approveOperationConfirmation()
                }
            }
            Button(String(localized: "取消", bundle: .module), role: .cancel) {
                agent.denyOperationConfirmation()
            }
        } message: { pending in
            Text(pending.detail)
        }
        .onChange(of: model.shouldPresentAssistantSearch) { _, shouldPresent in
            presentAssistantSearchIfNeeded()
        }
        .onAppear { presentAssistantSearchIfNeeded() }
    }

    // MARK: - Session sidebar

    private var sessionSidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Text(String(localized: "会话", bundle: .module)).font(.headline)
                    .foregroundStyle(theme.colorTokens.primaryText.color)
                Spacer()
                Button {
                    Task { await agent.newSession() }
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 24, weight: .semibold))
                        .frame(width: 52, height: 52)
                        .contentShape(Circle())
                }
                .buttonStyle(HapticBorderedButtonStyle())
                .help(String(localized: "新建会话", bundle: .module))
                sessionSettingsMenu
            }
            .padding(.horizontal, AuralisSpacing.medium)
            .padding(.top, AuralisSpacing.medium)

            HStack(spacing: AuralisSpacing.xSmall) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(theme.colorTokens.secondaryText.color)
                TextField(String(localized: "搜索会话", bundle: .module), text: $agent.sessionQuery)
                    .textFieldStyle(.plain)
            }
            .padding(AuralisSpacing.small)
            .background(theme.colorTokens.surface.color)
            .clipShape(RoundedRectangle(cornerRadius: AuralisRadius.small))
            .padding(.horizontal, AuralisSpacing.medium)
            .padding(.vertical, AuralisSpacing.small)

            List {
                ForEach(agent.sessions) { session in
                    if isBatchManaging {
                        batchSessionRow(session)
                    } else {
                        sessionRow(session)
                    }
                }
            }
            .listStyle(.plain)
            #if os(macOS)
            .frame(minHeight: 320)
            .scrollContentBackground(.hidden)
            .background(theme.colorTokens.elevated.color)
            #endif

            if isBatchManaging {
                HStack(spacing: AuralisSpacing.small) {
                    Button {
                        Task {
                            await agent.archive(Array(selectedSessionIDs))
                            selectedSessionIDs.removeAll()
                        }
                    } label: {
                        Label(String(localized: "归档", bundle: .module), systemImage: "archivebox")
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    #if os(macOS)
                    // macOS 使用原生按钮样式，确保鼠标命中区域和视觉按钮一致；
                    // iOS/iPadOS 继续保留带触感的移动端样式。
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    #else
                    .buttonStyle(HapticBorderedButtonStyle())
                    #endif
                    .accessibilityIdentifier("assistant.batch.archive")
                    .disabled(selectedSessionIDs.isEmpty)
                    Button(role: .destructive) {
                        confirmBatchDelete = true
                    } label: {
                        Label(String(localized: "删除", bundle: .module), systemImage: "trash")
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    #if os(macOS)
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    #else
                    .buttonStyle(HapticDestructiveButtonStyle())
                    #endif
                    .accessibilityIdentifier("assistant.batch.delete")
                    .disabled(selectedSessionIDs.isEmpty)
                }
                .padding(.horizontal, AuralisSpacing.medium)
                .padding(.vertical, AuralisSpacing.small)
            }
            Divider()
            Button {
                presentedSheet = .actionLog
            } label: {
                Label(
                    String(localized: "操作记录（\(agent.actionRecords.count)）", bundle: .module),
                    systemImage: "list.bullet.rectangle"
                )
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(HapticPlainButtonStyle())
            .padding(AuralisSpacing.medium)
        }
        .background(theme.colorTokens.elevated.color)
        // 确认框必须挂在会话 sheet 内：macOS 上如果挂在外层 AssistantView，
        // sheet 会遮住确认框，用户会看到按钮有按下反馈却没有任何结果。
        .alert(String(localized: "删除 \(selectedSessionIDs.count) 个会话？", bundle: .module), isPresented: $confirmBatchDelete) {
            Button(String(localized: "删除", bundle: .module), role: .destructive) {
                let ids = Array(selectedSessionIDs)
                selectedSessionIDs.removeAll()
                Task { await agent.delete(ids) }
            }
            Button(String(localized: "取消", bundle: .module), role: .cancel) { confirmBatchDelete = false }
        } message: {
            Text(String(localized: "选中的会话及其消息会从本机删除，不影响音乐库与服务器数据。", bundle: .module))
        }
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
                    Text(session.summary ?? String(localized: "\(session.messages.count) 条消息", bundle: .module))
                        .font(.caption2)
                        .lineLimit(1)
                        .foregroundStyle(theme.colorTokens.secondaryText.color)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            // 会话行整行至少 44pt 可点，行高与视觉不变。
            .frame(minHeight: 44)
        }
        .buttonStyle(HapticPlainButtonStyle())
        .listRowBackground(
            session.id == agent.activeSessionID
                ? theme.colorTokens.accent.color.opacity(0.16)
                : Color.clear
        )
        .contextMenu {
            Button(session.isPinned ? String(localized: "取消置顶", bundle: .module) : String(localized: "置顶", bundle: .module)) {
                Task { await agent.togglePin(session.id) }
            }
            Button(String(localized: "重命名", bundle: .module)) {
                renameText = session.title
                renamingSession = session
            }
            Button(String(localized: "清空消息", bundle: .module)) {
                Task { await agent.clearMessages(session.id) }
            }
            if session.isArchived {
                Button(String(localized: "取消归档", bundle: .module)) { Task { await agent.unarchive(session.id) } }
            } else {
                Button(String(localized: "归档", bundle: .module)) { Task { await agent.archive(session.id) } }
            }
            Divider()
            Button(String(localized: "删除", bundle: .module), role: .destructive) { deletingSession = session }
        }
    }

    /// 批量管理模式下的会话行：点击勾选/取消，不切换当前会话。
    private func batchSessionRow(_ session: AgentSession) -> some View {
        let isSelected = selectedSessionIDs.contains(session.id)
        return Button {
            if isSelected {
                selectedSessionIDs.remove(session.id)
            } else {
                selectedSessionIDs.insert(session.id)
            }
        } label: {
            HStack(spacing: AuralisSpacing.small) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(
                        isSelected ? theme.colorTokens.accent.color : theme.colorTokens.secondaryText.color
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.title)
                        .font(.subheadline)
                        .lineLimit(1)
                        .foregroundStyle(theme.colorTokens.primaryText.color)
                    Text(session.summary ?? String(localized: "\(session.messages.count) 条消息", bundle: .module))
                        .font(.caption2)
                        .lineLimit(1)
                        .foregroundStyle(theme.colorTokens.secondaryText.color)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            // 批量模式行同样保持整行 44pt 可点。
            .frame(minHeight: 44)
        }
        .buttonStyle(HapticPlainButtonStyle())
        .listRowBackground(
            isSelected
                ? theme.colorTokens.accent.color.opacity(0.16)
                : (session.id == agent.activeSessionID ? theme.colorTokens.accent.color.opacity(0.10) : Color.clear)
        )
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
                        conversationMessageRows()
                        if agent.isRunning { runningIndicator }
                        Color.clear
                            .frame(height: 1)
                            .id(Self.conversationEndID)
                    }
                    .padding(AuralisSpacing.large)
                    .background {
                        GeometryReader { geometry in
                            Color.clear.preference(
                                key: AssistantConversationContentBottomPreferenceKey.self,
                                value: geometry.frame(in: .named(Self.conversationScrollCoordinateSpace)).maxY
                            )
                        }
                    }
                    // 点击聊天空白区域收起键盘（不影响卡片自身的点按）。
                    .onTapGesture { assistantInputFocused = false }
                }
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(
                            key: AssistantConversationViewportBottomPreferenceKey.self,
                            value: geometry.frame(in: .named(Self.conversationScrollCoordinateSpace)).maxY
                        )
                    }
                }
                .coordinateSpace(name: Self.conversationScrollCoordinateSpace)
                .reportsBottomDockScroll(source: .assistant)
                // 向下拖动聊天列表时交互式收起键盘。
                .scrollDismissesKeyboard(.immediately)
                // 首次打开 / 切换历史会话也必须落在最新消息，而不仅是新消息 append 时。
                .onAppear {
                    isFollowingConversationOutput = true
                    scrollConversationToEnd(proxy, animated: false, force: true)
                }
                .onChange(of: agent.activeSessionID) { _, _ in
                    isFollowingConversationOutput = true
                    scrollConversationToEnd(proxy, animated: false, force: true)
                }
                .onChange(of: agent.messages.count) { _, _ in
                    scrollConversationToEnd(proxy, animated: true)
                }
                // 流式文字与工具进度通常替换同一条消息，消息数量不变；监听发布事件
                // 并延后一帧，等新高度完成布局后再贴到底部。
                .onReceive(agent.objectWillChange) { _ in
                    scrollConversationToEnd(proxy, animated: false)
                }
                .onPreferenceChange(AssistantConversationViewportBottomPreferenceKey.self) { value in
                    conversationViewportBottom = value
                    updateConversationAutoFollowState()
                }
                .onPreferenceChange(AssistantConversationContentBottomPreferenceKey.self) { value in
                    conversationContentBottom = value
                    updateConversationAutoFollowState()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #if os(iOS)
        // 输入框作为底部安全区浮层：只有它响应键盘安全区（随键盘上移），
        // 主菜单栏由根 Dock 覆盖层渲染并忽略键盘（固定在屏幕底部、被键盘遮挡）。
        // 根 Shell 在 AI 页不再重复保留 Dock 高度，避免输入框与 Dock 叠加避让。
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let coordinator = bottomDockScroll {
                AssistantDockInputProgressHost(
                    coordinator: coordinator,
                    model: model,
                    agent: agent,
                    theme: theme,
                    focus: $assistantInputFocused,
                    focused: assistantInputFocused
                )
            } else {
                // 保留独立预览 / 测试构造 AssistantView 时的安全默认值。
                AssistantDockInputBarLayout(
                    model: model,
                    agent: agent,
                    theme: theme,
                    focus: $assistantInputFocused,
                    focused: assistantInputFocused,
                    metrics: .standard,
                    collapseProgress: 0
                )
            }
        }
        #else
        // macOS：AI 输入胶囊与常规悬浮播放条共用窗口底部基线。AI 页的播放封面
        // 球已转移到 sidebar，detail 不再预留播放条高度或将输入框向上抬起。
        .safeAreaInset(edge: .bottom, spacing: 0) {
            inputBar
                .padding(.bottom, MacUIVisualTokens.FloatingPlayer.bottomInset)
        }
        #endif
    }

    /// Keep live reasoning immediately before the assistant messages produced
    /// by the current turn. Rendering it after the whole transcript made a
    /// completed answer appear first while the run was still finishing, which
    /// inverted the intended process → answer hierarchy.
    @ViewBuilder
    private func conversationMessageRows() -> some View {
        let reasoning: String? = {
            guard let presentation = agent.runPresentationState else { return nil }
            let text = presentation.reasoningText
            return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
        }()
        let latestUserIndex = agent.messages.lastIndex(where: { $0.role == .user })

        // A run normally always emits its user message first. Keep a safe
        // fallback for restored/compatibility states so reasoning cannot land
        // below an existing assistant answer when that anchor is absent.
        if let reasoning, latestUserIndex == nil {
            transientReasoningRow(reasoning)
        }

        ForEach(Array(agent.messages.enumerated()), id: \.element.id) { index, message in
            if let reasoning,
               let latestUserIndex,
               index == latestUserIndex + 1 {
                transientReasoningRow(reasoning)
            }
            messageRow(message).id(message.id)
        }

        // When the run has only emitted the user message so far, place the
        // live row after that message; subsequent assistant output will render
        // below it on the next update.
        if let reasoning,
           let latestUserIndex,
           latestUserIndex == agent.messages.count - 1 {
            transientReasoningRow(reasoning)
        }
    }

    private func scrollConversationToEnd(
        _ proxy: ScrollViewProxy,
        animated: Bool,
        force: Bool = false
    ) {
        // Capture the state before the new streaming chunk changes content
        // height. A large single chunk can temporarily move the bottom more
        // than the threshold before this async scroll runs; that must not
        // make a user who was already following output fall behind.
        let shouldFollow = force || isFollowingConversationOutput
        guard shouldFollow else { return }
        DispatchQueue.main.async {
            if animated {
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(Self.conversationEndID, anchor: .bottom)
                }
            } else {
                proxy.scrollTo(Self.conversationEndID, anchor: .bottom)
            }
        }
    }

    private func updateConversationAutoFollowState() {
        guard conversationViewportBottom > 0 else { return }
        isFollowingConversationOutput = conversationContentBottom - conversationViewportBottom
            <= Self.autoFollowThreshold
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
                Label(String(localized: "未配置模型接口", bundle: .module), systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(theme.colorTokens.warning.color)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if !isLive {
                Button { model.selectTopLevelSection(.settings) } label: {
                    Label(String(localized: "配置", bundle: .module), systemImage: "gearshape")
                }
                .buttonStyle(HapticBorderedButtonStyle())
                .controlSize(.small)
            }
            assistantHeaderIconButton(
                symbol: "magnifyingglass",
                accessibilityLabel: String(localized: "搜索音乐库", bundle: .module),
                help: String(localized: "搜索音乐库（兜底）", bundle: .module)
            ) {
                presentedSheet = .librarySearch
            }
            sessionListButton
        }
        .padding(AuralisSpacing.large)
        .accessibilityElement(children: .contain)
    }

    /// 新建会话仅保留在会话页顶部；进入批量管理后，全选收纳到同一管理按钮中。
    private var sessionSettingsMenu: some View {
        Menu {
            Toggle(String(localized: "显示已归档", bundle: .module), isOn: $agent.showArchivedSessions)
            Divider()
            if isBatchManaging {
                Button(selectedSessionIDs.count == agent.sessions.count && !agent.sessions.isEmpty ? String(localized: "取消全选", bundle: .module) : String(localized: "全选", bundle: .module)) {
                    if selectedSessionIDs.count == agent.sessions.count {
                        selectedSessionIDs.removeAll()
                    } else {
                        selectedSessionIDs = Set(agent.sessions.map(\.id))
                    }
                }
                Button(String(localized: "完成批量管理", bundle: .module)) {
                    isBatchManaging = false
                    selectedSessionIDs.removeAll()
                }
            } else {
                Button(String(localized: "管理会话", bundle: .module)) { isBatchManaging = true }
            }
        }
        label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 24, weight: .semibold))
                .frame(width: 52, height: 52)
        }
        .buttonStyle(HapticBorderedButtonStyle())
        .help(String(localized: "会话设置", bundle: .module))
        .accessibilityLabel(String(localized: "会话设置", bundle: .module))
    }

    private var sessionListButton: some View {
        assistantHeaderIconButton(
            symbol: "sidebar.leading",
            accessibilityLabel: String(localized: "会话列表", bundle: .module),
            help: String(localized: "会话列表", bundle: .module)
        ) {
            // iPhone / iPad 统一：会话列表始终以 sheet 呈现。
            presentedSheet = .sessions
        }
    }

    private func presentAssistantSearchIfNeeded() {
        guard model.shouldPresentAssistantSearch else { return }
        model.shouldPresentAssistantSearch = false
        presentedSheet = .librarySearch
    }

    /// 统一助手标题栏图标按钮的字形框和点击框。SF Symbol 的实际绘制边界不同，
    /// 若直接并排放置，虽然 HStack 以中心对齐，墨迹中心仍会显得上下偏移。
    private func assistantHeaderIconButton(
        symbol: String,
        accessibilityLabel: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 19, weight: .medium))
                // 先统一符号的光学画布，再统一 44pt 点击区域。
                .frame(width: 24, height: 24, alignment: .center)
                .frame(width: 44, height: 44, alignment: .center)
                .contentShape(Rectangle())
        }
        .buttonStyle(HapticPlainButtonStyle())
        .accessibilityLabel(accessibilityLabel)
        .help(help)
    }

    @ViewBuilder
    private var emptyState: some View {
        // 空会话不再展示常驻示例词，避免在用户尚未输入前占用首屏空间。
        // 仅在确实无法读取音乐库时保留必要的状态说明。
        if !model.catalog.isConnected {
            Label(String(localized: "尚未连接服务器，本地目录为空", bundle: .module), systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(theme.colorTokens.warning.color)
        }
    }

    private var runningIndicator: some View {
        HStack(spacing: AuralisSpacing.small) {
            ProgressView().controlSize(.small)
            // RunPresentationState is the single source of truth while a run
            // is active.  AgentTask remains useful for persisted deterministic
            // workflow diagnostics, but must not race a generic streaming run.
            Text(agent.runPresentationState?.phase.displayText
                 ?? String(localized: "正在处理…", bundle: .module)).font(.caption2)
                .foregroundStyle(theme.colorTokens.secondaryText.color)
            Button(String(localized: "停止", bundle: .module)) { agent.cancel() }
                .buttonStyle(HapticBorderedButtonStyle())
                .controlSize(.small)
        }
    }

    /// 思考内容只从 `AssistantRunPresentationState` 读取，运行结束即被清除，
    /// 不会作为 `AgentChatMessage` 写入本地会话或被后续模型调用回放。
    private func transientReasoningRow(_ reasoning: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label("思考中…", systemImage: "brain.head.profile")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(theme.colorTokens.secondaryText.color)
            ChatMarkdownContent(source: reasoning, compact: true)
                .foregroundStyle(theme.colorTokens.secondaryText.color)
                .opacity(0.82)
                .textSelection(.enabled)
                .frame(maxHeight: 120, alignment: .topLeading)
                .clipped()
        }
        .padding(.horizontal, AuralisSpacing.small)
        .padding(.vertical, 4)
        .background(theme.colorTokens.surface.color.opacity(0.24))
        .clipShape(RoundedRectangle(cornerRadius: AuralisRadius.medium))
        .frame(maxWidth: 560, alignment: .leading)
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
            VStack(alignment: isUser ? .trailing : .leading, spacing: AuralisSpacing.small) {
                ChatMarkdownContent(source: text)
                    .foregroundStyle(theme.colorTokens.primaryText.color)
                    .textSelection(.enabled)

                // 不依赖系统的分享/拖放路径：复制时只向剪贴板写入 String，
                // 粘贴到 Mac 或其他 App 时就是文本而不是附件文件。
                if !isUser {
                    Button {
                        AssistantTextPasteboard.copy(text)
                    } label: {
                        Label(String(localized: "复制", bundle: .module), systemImage: "doc.on.doc")
                            .font(.caption.weight(.medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.colorTokens.secondaryText.color)
                    .accessibilityLabel(String(localized: "复制 AI 回复文本", bundle: .module))
                }
            }
            .padding(AuralisSpacing.medium)
            .background(isUser ? theme.colorTokens.accent.color.opacity(0.22) : theme.colorTokens.elevated.color)
            .clipShape(RoundedRectangle(cornerRadius: AuralisRadius.medium))
            .frame(maxWidth: 560, alignment: isUser ? .trailing : .leading)
            .contextMenu {
                Button {
                    AssistantTextPasteboard.copy(text)
                } label: {
                    Label(String(localized: "复制文本", bundle: .module), systemImage: "doc.on.doc")
                }
            }

        // 流式输出中的 assistant 文本：增量追加，末尾带呼吸光标示意「正在生成」。
        case let .streaming(text):
            HStack(alignment: .bottom, spacing: 2) {
                ChatMarkdownContent(source: text.isEmpty ? " " : text)
                    .foregroundStyle(theme.colorTokens.primaryText.color)
                Text("▌")
                    .foregroundStyle(theme.colorTokens.accent.color)
                    .opacity(0.8)
            }
            .padding(AuralisSpacing.medium)
            .background(theme.colorTokens.elevated.color.opacity(0.7))
            .clipShape(RoundedRectangle(cornerRadius: AuralisRadius.medium))
            .frame(maxWidth: 560, alignment: .leading)
            .textSelection(.enabled)

        // Reasoning is never meant to survive as a chat-message payload.  If
        // an older/corrupt local session contains one, keep it invisible
        // rather than revealing or replaying it as a durable assistant answer.
        case .reasoning:
            EmptyView()

        case let .trackCards(cards):
            TrackCardList(cards: cards, agent: agent, theme: theme)

        case let .albumCards(cards):
            AlbumCardList(cards: cards, theme: theme)

        case let .playlistCards(cards):
            PlaylistCardList(cards: cards, theme: theme)

        case let .artistCards(cards):
            ArtistCardList(cards: cards, theme: theme)

        case let .webSources(sources):
            VStack(alignment: .leading, spacing: AuralisSpacing.small) {
                Label(String(localized: "联网来源", bundle: .module), systemImage: "globe")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.colorTokens.primaryText.color)
                ForEach(sources) { source in
                    Link(destination: source.url) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(source.title)
                                .font(.caption.weight(.medium))
                                .lineLimit(2)
                            Text(source.domain)
                                .font(.caption2)
                                .foregroundStyle(theme.colorTokens.secondaryText.color)
                            if let publishedAt = source.publishedAt, !publishedAt.isEmpty {
                                Text(publishedAt)
                                    .font(.caption2)
                                    .foregroundStyle(theme.colorTokens.secondaryText.color)
                            }
                            if !source.snippet.isEmpty {
                                Text(source.snippet)
                                    .font(.caption2)
                                    .foregroundStyle(theme.colorTokens.secondaryText.color)
                                    .lineLimit(3)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(AuralisSpacing.medium)
            .background(theme.colorTokens.elevated.color)
            .clipShape(RoundedRectangle(cornerRadius: AuralisRadius.medium))
            .frame(maxWidth: 560, alignment: .leading)

        case let .playlistProposal(name, tracks):
            VStack(alignment: .leading, spacing: AuralisSpacing.small) {
                HStack {
                    Label(name, systemImage: "music.note.list")
                        .font(.headline)
                        .foregroundStyle(theme.colorTokens.primaryText.color)
                    Spacer()
                    Button(String(localized: "全部播放", bundle: .module)) { agent.playAll(cards: tracks) }
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
                Text(title).font(.caption2.weight(.semibold))
                    .foregroundStyle(theme.colorTokens.secondaryText.color)
                Text(detail).font(.caption2)
                    .foregroundStyle(theme.colorTokens.secondaryText.color)
            }
            .padding(.horizontal, AuralisSpacing.small)
            .padding(.vertical, 4)
            .background(theme.colorTokens.surface.color.opacity(0.22))
            .clipShape(RoundedRectangle(cornerRadius: AuralisRadius.small))

        case let .toolProgress(step):
            Label(step, systemImage: "gearshape.arrow.trianglehead.2.clockwise.rotate.90")
                .font(.caption2)
                .foregroundStyle(theme.colorTokens.secondaryText.color)
                .opacity(0.78)

        case let .error(text):
            Label(text, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(theme.colorTokens.error.color)

        case let .confirmation(pending):
            Label(
                String(localized: "等待确认：\(pending.title)", bundle: .module),
                systemImage: "questionmark.circle"
            )
                .font(.caption)
                .foregroundStyle(theme.colorTokens.warning.color)
        }
    }

    /// 输入框（macOS 版）：液态玻璃胶囊，固定在与常规播放条相同的底部基线。
    /// iOS 版的输入框由底部 Dock 统一渲染（见 AuralisRootView 的 DockAssistantInputBar），
    /// 避免嵌套 safeAreaInset 与 Dock 主菜单栏重叠。
    #if os(macOS)
    private var inputBar: some View {
        MacGlassCapsule {
            HStack(alignment: .center, spacing: AuralisSpacing.medium) {
                Image(systemName: "sparkles")
                    .foregroundStyle(theme.colorTokens.accent.color)
                    .frame(width: 22, height: 22)
                TextField(String(localized: "描述你想听的音乐，或让我帮你操作", bundle: .module), text: $model.assistantDraft)
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
                .accessibilityLabel(model.assistantIsRunning ? String(localized: "停止", bundle: .module) : String(localized: "发送", bundle: .module))
                .frame(width: 44, height: 44)
            }
            .padding(.horizontal, 16)
            .frame(height: 62)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
    }
    #endif

    private func permissionLabel(_ permission: ToolPermission) -> String {
        switch permission {
        case .readOnly: String(localized: "只读操作", bundle: .module)
        case .reversible: String(localized: "可撤销操作", bundle: .module)
        case .destructive: String(localized: "破坏性操作（不可自动恢复）", bundle: .module)
        }
    }
}

#if os(iOS)
/// 只让 AI 输入栏订阅 HomeChromeState。聊天页本身不需要因 Dock 进度变化而重算。
private struct AssistantDockInputProgressHost: View {
    @ObservedObject var coordinator: HomeChromeState
    @ObservedObject var model: AuralisAppModel
    @ObservedObject var agent: AgentCoordinator
    let theme: BuiltInTheme
    var focus: FocusState<Bool>.Binding
    let focused: Bool

    var body: some View {
        AssistantDockInputBarLayout(
            model: model,
            agent: agent,
            theme: theme,
            focus: focus,
            focused: focused,
            metrics: coordinator.metrics,
            collapseProgress: coordinator.collapseProgress
        )
    }
}

/// 输入栏的安全区布局保持为纯参数视图，便于无 UI 回归测试验证两端几何。
private struct AssistantDockInputBarLayout: View {
    @ObservedObject var model: AuralisAppModel
    @ObservedObject var agent: AgentCoordinator
    let theme: BuiltInTheme
    var focus: FocusState<Bool>.Binding
    let focused: Bool
    let metrics: BottomChromeMetrics
    let collapseProgress: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        DockAssistantInputBar(model: model, agent: agent, theme: theme, focus: focus)
            // iPad 宽屏：与底部 Dock 共用同一浮动控件最大宽度并居中，不横贯整屏。
            .frame(maxWidth: IOSLayoutMetrics.floatingChromeMaxWidth)
            .frame(maxWidth: .infinity)
            .padding(
                .horizontal,
                AssistantDockInputLayout.horizontalPadding(
                    focused: focused,
                    metrics: metrics,
                    collapseProgress: collapseProgress
                )
            )
            .padding(
                .bottom,
                AssistantDockInputLayout.bottomPadding(
                    focused: focused,
                    metrics: metrics,
                    collapseProgress: collapseProgress
                )
            )
            // 输入框与根 Dock 读取同一个端点状态，并使用同一固定时长曲线。
            .animation(
                BottomDockMotion.animation(reduceMotion: reduceMotion),
                value: collapseProgress
            )
    }
}
#endif

/// 助手回答一律作为纯文本复制，避免 `ShareLink` / 文本拖放将长消息导出为文件。
private enum AssistantTextPasteboard {
    static func copy(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}

// MARK: - Markdown message content

/// 以有限、稳定的 Markdown 子集渲染聊天内容。
/// 标题、列表和段落分别布局，避免把长篇回答挤成一整块普通文字。
private struct ChatMarkdownContent: View {
    private enum Block {
        case heading(level: Int, text: String)
        case bullet(marker: String, text: String)
        case paragraph(String)
    }

    let source: String
    /// Process text (reasoning/tool activity) must stay visually subordinate
    /// even when it contains Markdown headings or lists. The final answer
    /// keeps the richer body hierarchy by using the default style.
    var compact = false

    var body: some View {
        let blocks = Self.parse(source)
        VStack(alignment: .leading, spacing: compact ? 3 : 9) {
            ForEach(blocks.indices, id: \.self) { index in
                blockView(blocks[index])
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func blockView(_ block: Block) -> some View {
        switch block {
        case let .heading(level, text):
            richText(text)
                .font(compact
                    ? .caption.weight(.regular)
                    : (level == 1 ? .title3.weight(.bold) : .headline.weight(.semibold)))
                .padding(.top, compact ? 0 : (level == 1 ? 2 : 0))
        case let .bullet(marker, text):
            HStack(alignment: .firstTextBaseline, spacing: compact ? 4 : 8) {
                Text(marker)
                    .font(compact ? .caption2.weight(.regular) : .subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: compact ? 10 : 15, alignment: .trailing)
                richText(text)
                    .lineSpacing(compact ? 0 : 2)
                    .font(compact ? .caption2 : .body)
            }
        case let .paragraph(text):
            richText(text)
                .lineSpacing(compact ? 0 : 3)
                .font(compact ? .caption2 : .body)
        }
    }

    /// 保留行内强调、链接和代码；流式时遇到不完整 Markdown 则显示原文。
    private func richText(_ source: String) -> Text {
        // Process text must not regain body-sized emphasis through Markdown
        // attributes.  Its container already applies the compact hierarchy;
        // a plain Text keeps headings/strong spans subordinate as well.
        guard !compact else { return Text(source) }
        guard let attributed = try? AttributedString(
            markdown: source,
            options: .init(interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible)
        ) else {
            return Text(source)
        }
        return Text(attributed)
    }

    private static func parse(_ source: String) -> [Block] {
        var blocks: [Block] = []
        var paragraphLines: [String] = []

        func flushParagraph() {
            let text = paragraphLines.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { blocks.append(.paragraph(text)) }
            paragraphLines.removeAll()
        }

        for rawLine in source.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else {
                flushParagraph()
                continue
            }

            if line.hasPrefix("### ") {
                flushParagraph()
                blocks.append(.heading(level: 2, text: String(line.dropFirst(4))))
            } else if line.hasPrefix("## ") {
                flushParagraph()
                blocks.append(.heading(level: 2, text: String(line.dropFirst(3))))
            } else if line.hasPrefix("# ") {
                flushParagraph()
                blocks.append(.heading(level: 1, text: String(line.dropFirst(2))))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                flushParagraph()
                blocks.append(.bullet(marker: "•", text: String(line.dropFirst(2))))
            } else if let range = line.range(of: #"^\d+\.\s+"#, options: .regularExpression) {
                flushParagraph()
                let marker = String(line[..<range.upperBound]).trimmingCharacters(in: .whitespaces)
                blocks.append(.bullet(marker: marker, text: String(line[range.upperBound...])))
            } else {
                paragraphLines.append(line)
            }
        }
        flushParagraph()
        return blocks.isEmpty ? [.paragraph(source)] : blocks
    }
}

// MARK: - Track cards

/// 结构化歌曲卡片列表。每张卡片都带真实 GlobalTrackID，点击即本地播放。
/// 结构化歌曲卡片列表：默认只展示前 5 首，超出部分可展开。
/// 避免搜索结果 / 歌手相关歌曲一次性铺满整个对话。
private struct TrackCardList: View {
    let cards: [TrackCard]
    @ObservedObject var agent: AgentCoordinator
    let theme: BuiltInTheme
    @State private var expanded = false

    var body: some View {
        VStack(spacing: AuralisSpacing.xSmall) {
            ForEach(expanded ? cards : Array(cards.prefix(5))) { card in
                TrackCardRow(card: card, agent: agent, theme: theme)
            }
            if cards.count > 5 {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
                } label: {
                    Label(
                        expanded ? String(localized: "收起", bundle: .module) : String(localized: "展开其余 \(cards.count - 5) 首", bundle: .module),
                        systemImage: expanded ? "chevron.up" : "chevron.down"
                    )
                        .font(.caption)
                        .foregroundStyle(theme.colorTokens.accent.color)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: 560, alignment: .leading)
    }
}

/// 专辑卡片列表：默认只展示前 5 张，超出部分可展开。
private struct AlbumCardList: View {
    let cards: [AlbumCard]
    let theme: BuiltInTheme
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: AuralisSpacing.xSmall) {
            ForEach(expanded ? cards : Array(cards.prefix(5))) { card in
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
            if cards.count > 5 {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
                } label: {
                    Label(
                        expanded ? String(localized: "收起", bundle: .module) : String(localized: "展开其余 \(cards.count - 5) 张", bundle: .module),
                        systemImage: expanded ? "chevron.up" : "chevron.down"
                    )
                        .font(.caption)
                        .foregroundStyle(theme.colorTokens.accent.color)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: 560, alignment: .leading)
    }
}

private struct PlaylistCardList: View {
    let cards: [PlaylistCard]
    let theme: BuiltInTheme
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: AuralisSpacing.xSmall) {
            ForEach(expanded ? cards : Array(cards.prefix(5))) { card in
                HStack {
                    Image(systemName: "music.note.list")
                        .foregroundStyle(theme.colorTokens.accent.color)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(card.name).font(.subheadline)
                            .foregroundStyle(theme.colorTokens.primaryText.color)
                        Text("\(card.trackCount) 首 · \(card.isReadOnly ? String(localized: "只读", bundle: .module) : String(localized: "可编辑", bundle: .module))")
                            .font(.caption2)
                            .foregroundStyle(theme.colorTokens.secondaryText.color)
                    }
                    Spacer()
                }
                .padding(AuralisSpacing.small)
                .background(theme.colorTokens.elevated.color)
                .clipShape(RoundedRectangle(cornerRadius: AuralisRadius.small))
            }
            if cards.count > 5 {
                expandButton
            }
        }
        .frame(maxWidth: 560, alignment: .leading)
    }

    private var expandButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
        } label: {
            Label(
                expanded ? String(localized: "收起", bundle: .module) : String(localized: "展开其余 \(cards.count - 5) 个", bundle: .module),
                systemImage: expanded ? "chevron.up" : "chevron.down"
            )
            .font(.caption)
            .foregroundStyle(theme.colorTokens.accent.color)
        }
        .buttonStyle(.plain)
    }
}

private struct ArtistCardList: View {
    let cards: [ArtistCard]
    let theme: BuiltInTheme
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: AuralisSpacing.xSmall) {
            ForEach(expanded ? cards : Array(cards.prefix(5))) { card in
                HStack {
                    Image(systemName: "person.crop.circle")
                        .foregroundStyle(theme.colorTokens.accent.color)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(card.name).font(.subheadline)
                            .foregroundStyle(theme.colorTokens.primaryText.color)
                        Text("\(card.albumCount) 张专辑")
                            .font(.caption2)
                            .foregroundStyle(theme.colorTokens.secondaryText.color)
                    }
                    Spacer()
                }
                .padding(AuralisSpacing.small)
                .background(theme.colorTokens.elevated.color)
                .clipShape(RoundedRectangle(cornerRadius: AuralisRadius.small))
            }
            if cards.count > 5 {
                expandButton
            }
        }
        .frame(maxWidth: 560, alignment: .leading)
    }

    private var expandButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
        } label: {
            Label(
                expanded ? String(localized: "收起", bundle: .module) : String(localized: "展开其余 \(cards.count - 5) 位", bundle: .module),
                systemImage: expanded ? "chevron.up" : "chevron.down"
            )
            .font(.caption)
            .foregroundStyle(theme.colorTokens.accent.color)
        }
        .buttonStyle(.plain)
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
                .help(String(localized: "播放", bundle: .module))

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
                .help(card.isFavorite ? String(localized: "取消喜爱", bundle: .module) : String(localized: "喜爱", bundle: .module))

                Menu {
                    Button(String(localized: "加入队列", bundle: .module)) { agent.queue(card: card) }
                    Divider()
                    Section(String(localized: "推荐反馈", bundle: .module)) {
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
                Text(String(localized: "操作记录", bundle: .module)).font(.headline)
                Spacer()
                Button(String(localized: "清空", bundle: .module)) { Task { await agent.clearActionLog() } }
                    .buttonStyle(HapticBorderedButtonStyle())
                Button(String(localized: "完成", bundle: .module)) { dismiss() }
                    .buttonStyle(HapticProminentButtonStyle())
            }
            .padding(AuralisSpacing.medium)
            Divider()
            if agent.actionRecords.isEmpty {
                Spacer()
                Text(String(localized: "暂无修改型操作", bundle: .module)).foregroundStyle(theme.colorTokens.secondaryText.color)
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
                            Text(String(localized: "已撤销", bundle: .module)).font(.caption2)
                                .foregroundStyle(theme.colorTokens.secondaryText.color)
                        } else if record.permission == .reversible {
                            Button(String(localized: "撤销", bundle: .module)) { Task { await agent.undo(record) } }
                                .buttonStyle(HapticBorderedButtonStyle())
                                .controlSize(.small)
                        } else {
                            Text(String(localized: "不可撤销", bundle: .module)).font(.caption2)
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
