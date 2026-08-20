import DesignSystem
import Domain
import LocalCatalog
import SwiftUI
import ThemeEngine
#if os(iOS)
import CoreSpotlight
import UIKit
#endif

/// Dock 手势只负责选择最终状态，不再把手指位移映射成动画进度。
/// 因此同方向的快滑、慢滑都会以完全相同的时长完成展开或收拢。
struct BottomDockProgressReducer: Sendable {
    static let publicationEpsilon: CGFloat = 0.008
    /// 采用接近标准触控目标高度的有效位移，轻微抖动和短划不会切换 Dock。
    static let minimumVerticalSwipeDistance: CGFloat = 44

    static func shouldPublish(current: CGFloat, next: CGFloat) -> Bool {
        // 两端必须精确落在 0/1，确保最终布局和可访问性状态不漂移。
        if next == 0 || next == 1 { return current != next }
        return abs(next - current) >= publicationEpsilon
    }

    /// 纵向滑动结束后必须落到确定端点，不能把 Dock 留在半展开状态。
    /// 横向货架手势不会触发，避免与首页横向卡片滚动冲突。
    static func terminalProgress(for translation: CGSize) -> CGFloat? {
        guard abs(translation.height) > abs(translation.width),
              abs(translation.height) >= minimumVerticalSwipeDistance
        else { return nil }
        return translation.height < 0 ? 1 : 0
    }
}

/// Dock 本体、页面预留空间和 AI 输入框共用同一套固定节奏。
/// 动画只在手势结束、目标状态确定后启动，用户拖动速度不会改变它。
enum BottomDockMotion {
    static let duration: TimeInterval = 0.56

    static func animation(reduceMotion: Bool) -> Animation {
        reduceMotion
            ? .linear(duration: 0.18)
            : .smooth(duration: duration)
    }
}

/// 首页 / 音乐库的滚动进度。类型保持跨平台可见，让共享页面和环境注入在 macOS
/// 也能编译；只有 iOS 的 modifier 会真正向它报告滚动。
@MainActor
final class BottomDockScrollCoordinator: ObservableObject {
    @Published private(set) var collapseProgress: CGFloat = 0

    func finishInteraction(translation: CGSize) {
        guard let terminal = BottomDockProgressReducer.terminalProgress(for: translation) else { return }
        setCollapseProgress(terminal)
    }

    func reset() {
        setCollapseProgress(0)
    }

    func setCollapseProgress(_ progress: CGFloat) {
        let clamped = min(max(progress, 0), 1)
        guard BottomDockProgressReducer.shouldPublish(current: collapseProgress, next: clamped) else { return }
        collapseProgress = clamped
    }
}

private struct BottomDockScrollCoordinatorEnvironmentKey: EnvironmentKey {
    static let defaultValue: BottomDockScrollCoordinator? = nil
}

extension EnvironmentValues {
    var bottomDockScrollCoordinator: BottomDockScrollCoordinator? {
        get { self[BottomDockScrollCoordinatorEnvironmentKey.self] }
        set { self[BottomDockScrollCoordinatorEnvironmentKey.self] = newValue }
    }
}

public struct AuralisRootView: View {
    @StateObject private var model: AuralisAppModel
    @StateObject private var themeStore: ThemeStore
    /// 用 @State 只保持引用生命周期，不让每次滚动进度变化都使整个 AuralisRootView 失效。
    /// 真正需要重绘的 Dock 子视图会单独 @ObservedObject 订阅它。
    @State private var bottomDockScroll = BottomDockScrollCoordinator()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.scenePhase) private var scenePhase

    public init() {
        // 使用共享实例：快捷指令 / Siri 等系统入口与界面操作同一个播放服务。
        _model = StateObject(wrappedValue: AuralisAppModel.shared)
        _themeStore = StateObject(wrappedValue: ThemeStore())
    }

    /// 依赖注入：macOS 组合根创建唯一长期 ThemeStore / AppModel，
    /// 主窗口与 Settings Scene 共享同一实例（改主题后主窗口实时生效）。
    public init(model: AuralisAppModel, themeStore: ThemeStore) {
        _model = StateObject(wrappedValue: model)
        _themeStore = StateObject(wrappedValue: themeStore)
    }

    public var body: some View {
        Group {
#if os(macOS)
            MacMusicShell(model: model, themeStore: themeStore)
#elseif os(iOS)
            // iPhone 与 iPad 始终使用同一个 iOS Shell（同一导航 / 同一 Bottom Dock）。
            // size class 只允许影响局部布局尺寸，绝不允许切换整套 UI 架构——
            // Stage Manager / 分屏改变 horizontalSizeClass 时不能替换 root Shell。
            IOSMusicShell(model: model, themeStore: themeStore, bottomDockScroll: bottomDockScroll)
#endif
        }
        .environmentObject(model)
        .environmentObject(bottomDockScroll)
        .environment(\.bottomDockScrollCoordinator, bottomDockScroll)
        .environment(\.artworkStore, model.artworkStore)
        .environmentObject(themeStore)
        .preferredColorScheme(themeStore.current.colorScheme)
        .tint(themeStore.current.colorTokens.accent.color)
        .buttonStyle(HapticButtonStyle())
        .animation(reduceMotion ? nil : .easeInOut(duration: themeStore.current.motion.standardDuration), value: themeStore.selectedID)
        .environment(\.auralisReduceTransparency, reduceTransparency)
        .task { await model.restorePersistedLibrary() }
        .onOpenURL { url in
            model.handleIncomingURL(url)
        }
        .onContinueUserActivity("INPlayMediaIntent") { userActivity in
            model.handleSiriUserActivity(userActivity)
        }
#if os(iOS)
        .onContinueUserActivity(CSSearchableItemActionType) { userActivity in
            if let identifier = userActivity.userInfo?[CSSearchableItemActivityIdentifier] as? String {
                model.handleSpotlightIdentifier(identifier)
            }
        }
#endif
        .onContinueUserActivity("com.auralis.player.playback") { userActivity in
            model.handleHandoffActivity(userActivity)
        }
    }
}

/// 统一 iOS UI 的布局视觉 token（iPhone 与 iPad 共用同一套 Shell）。
/// 这些只是「可用宽度」约束，不承载任何业务状态：
/// - 浮动控件（Bottom Dock / AI 输入框）在 iPad 宽屏不铺满，居中、最大约 760pt；
/// - 可读内容宽度上限约 960pt；
/// - 播放页内容宽度上限约 680pt（与 NowPlayingView 既有策略一致）。
enum IOSLayoutMetrics {
    /// 底部浮动控件（Dock / 输入框）在宽屏的最大宽度。
    static let floatingChromeMaxWidth: CGFloat = 760
    /// 主内容容器可读宽度上限（宽屏居中）。
    static let readableContentMaxWidth: CGFloat = 960
    /// 播放页内容最大宽度。
    static let playerContentMaxWidth: CGFloat = 680
    /// 最小触控目标高度（44pt），回归测试守护不回退。
    static let minimumTouchTargetHeight: CGFloat = 44

    /// 浮动控件宽度：窄屏取满可用宽度，宽屏封顶 floatingChromeMaxWidth，无负数。
    static func floatingChromeWidth(containerWidth: CGFloat) -> CGFloat {
        min(max(containerWidth, 0), floatingChromeMaxWidth)
    }

    /// 可读内容宽度：窄屏取满可用宽度，宽屏封顶 readableContentMaxWidth。
    static func readableContentWidth(containerWidth: CGFloat) -> CGFloat {
        min(max(containerWidth, 0), readableContentMaxWidth)
    }
}

#if os(iOS)
/// 底部双层 Dock 两控件共享的可见高度（迷你播放条与主菜单栏完全一致）。
/// 之前 72pt 太大、占用过多纵向空间，现统一收小到 56pt。
let bottomBarHeight: CGFloat = 56
/// 两控件之间的固定间距（与 BottomDock 的 VStack spacing 同源）。
let dockSpacing: CGFloat = 8
/// Dock 整体的底部内边距（与 BottomDock 的 .padding(.bottom) 同源）。
let dockBottomPadding: CGFloat = 6


private struct IOSMusicShell: View {
    @ObservedObject var model: AuralisAppModel
    @ObservedObject var themeStore: ThemeStore
    let bottomDockScroll: BottomDockScrollCoordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationStack {
            DockReservedSectionContent(
                model: model,
                themeStore: themeStore,
                coordinator: bottomDockScroll,
                hasAccessory: hasDockAccessory
            )
                // Destination 必须注册在 NavigationStack 的内容树内。此前把 modifier
                // 挂在 NavigationStack 外层，状态虽已写入，但 SwiftUI 不会执行导航，
                // 因而首页、专辑、艺术家和歌单看起来都“点了没反应”。
                .navigationDestination(item: browseDestinationBinding) { destination in
                    BrowseDetailSheet(
                        destination: destination,
                        model: model,
                        theme: themeStore.current,
                        showsCloseButton: false
                    )
                }
                .navigationTitle(model.selectedSection.title)
                // 顶部标题用系统大标题：字体大、与正文内容有明显区分（Apple Music 风格）。
                // 不覆盖系统导航栏材质。iOS 26+ 会为标准导航栏自动采用 Liquid Glass；
                // 之前把这里强制涂成主题纯色，导致顶部仍是旧式、不透明的导航栏。
                .navigationBarTitleDisplayMode(.large)
        }
        // Dock 切换的是应用一级分区；若当前停在设置/资料库的二级 NavigationLink，
        // 必须丢弃旧路径并回到新分区根页，不能让二级页面“悬在”新的根内容之上。
        .id(model.selectedSection)
        .overlay(alignment: .bottom) {
            dockOverlay
                .ignoresSafeArea(.keyboard, edges: .bottom)
        }
        .sheet(isPresented: nowPlayingBinding) {
            NowPlayingView(model: model, theme: themeStore.current)
                .presentationDragIndicator(.visible)
                .presentationDetents([.large])
        }
        .sheet(isPresented: $model.shouldPresentServerSetup) {
            ServerConnectionSheet(model: model, theme: themeStore.current)
        }
        // 设置页没有底部附件；离开首页 / 音乐库 / AI 助手时回到完整导航态。
        .onChange(of: model.selectedSection) { _, _ in
            bottomDockScroll.reset()
        }
        .alert(String(localized: "播放失败", bundle: .module), isPresented: .init(
            get: { model.playbackError != nil },
            set: { if !$0 { model.dismissPlaybackError() } }
        )) {
            Button(String(localized: "重试", bundle: .module)) { model.retryPlayback() }
            if model.canGoNext {
                Button(String(localized: "下一首", bundle: .module)) { model.next() }
            }
            Button(String(localized: "确定", bundle: .module)) { model.dismissPlaybackError() }
        } message: {
            if let error = model.playbackError {
                switch error {
                case .networkUnavailable:
                    Text(String(localized: "网络不可用，请检查网络连接", bundle: .module))
                case .unsupportedFormat(let format):
                    Text("不支持的音频格式：\(format)")
                case .authorizationFailed:
                    Text(String(localized: "授权失败，请检查登录状态", bundle: .module))
                case .engineFailure(let message):
                    Text(message)
                }
            }
        }
    }

    private var showsPlaybackAccessory: Bool {
        model.selectedSection == .home || model.selectedSection == .library
    }

    private var showsAssistantAccessory: Bool {
        model.selectedSection == .assistant
    }

    private var hasDockAccessory: Bool {
        showsPlaybackAccessory || showsAssistantAccessory
    }

    private var collapsedDockAccessory: CollapsedDockAccessory? {
        if showsPlaybackAccessory { return .player }
        if showsAssistantAccessory { return .assistant }
        return nil
    }

    /// 同一 Dock 的两种布局：展开态对应 Apple Music 的完整底栏，紧凑态把播放附件
    /// 内联到导航栏。它们在同一个 ZStack 内缩放淡入淡出，避免出现两套栏位同时抢手势。
    @ViewBuilder
    private var dockOverlay: some View {
        MorphingBottomDockProgressHost(
            model: model,
            theme: themeStore.current,
            accessory: collapsedDockAccessory,
            coordinator: bottomDockScroll,
            onExpand: { setDockPresentation(.expanded) },
            onAssistant: {
                selectTopLevelSection(.assistant)
                setDockPresentation(.expanded)
            },
            onSelect: { selectTopLevelSection($0) }
        )
        // iPhone 窄屏接近全宽；iPad 宽屏最大约 760pt 并居中，不横贯整屏。
        .frame(maxWidth: IOSLayoutMetrics.floatingChromeMaxWidth)
        .frame(maxWidth: .infinity)
    }

    private var dockAnimation: Animation? {
        BottomDockMotion.animation(reduceMotion: reduceMotion)
    }

    private func setDockPresentation(_ presentation: DockPresentation) {
        withAnimation(dockAnimation) {
            bottomDockScroll.setCollapseProgress(presentation == .compact ? 1 : 0)
        }
    }

    /// 一级分区切换的唯一入口：必须同时清掉浏览详情（NavigationStack 的
    /// navigationDestination item），否则详情仍盖在新分区根页之上，表现为
    /// “歌单/收藏详情里点音乐库/AI 助手跳不过去”；同时重置底部 Dock 的滚动进度。
    private func selectTopLevelSection(_ section: AppSection) {
        model.selectTopLevelSection(section)
        bottomDockScroll.reset()
    }
    /// 互斥呈现：服务器配置弹窗优先；正在播放 / 浏览详情不会与它同时弹出，
    /// 避免 UIKit "Attempt to present … which is already presenting …" 冲突导致卡顿。
    private var nowPlayingBinding: Binding<Bool> {
        Binding(
            get: { model.isNowPlayingPresented && !model.shouldPresentServerSetup },
            set: { newValue in
                if !newValue {
                    model.isNowPlayingPresented = false
                } else if !model.shouldPresentServerSetup {
                    model.isNowPlayingPresented = true
                }
            }
        )
    }

    private var browseDestinationBinding: Binding<BrowseDestination?> {
        Binding(
            get: { model.shouldPresentServerSetup ? nil : model.browseDestination },
            set: { model.browseDestination = $0 }
        )
    }

}

/// 底部安全区的连续变化仍保留原有最终布局，但订阅被限制在当前 SectionContent，
/// 不再使 NavigationStack、弹窗绑定和整个 RootView 跟随滚动重算。
private struct DockReservedSectionContent: View {
    @ObservedObject var model: AuralisAppModel
    @ObservedObject var themeStore: ThemeStore
    @ObservedObject var coordinator: BottomDockScrollCoordinator
    let hasAccessory: Bool

    var body: some View {
        SectionContent(section: model.selectedSection, model: model, themeStore: themeStore)
            .environment(\.bottomDockReservedHeight, reservedHeight)
    }

    private var reservedHeight: CGFloat {
        let singleBar = bottomBarHeight + dockBottomPadding
        guard hasAccessory else { return singleBar }
        let expandedHeight = bottomBarHeight + dockSpacing + singleBar
        return expandedHeight + (singleBar - expandedHeight) * coordinator.collapseProgress
    }
}

private enum DockPresentation: Equatable {
    case expanded
    case compact
}

/// 应加在真正可纵向滚动的 ScrollView 或 List 上。手势与系统滚动同时识别，
/// 只读取纵向位移来驱动 Dock，不接管列表点击和横向货架。
struct BottomDockScrollReportingModifier: ViewModifier {
    /// 普通 Environment 值只传递引用，不会订阅 objectWillChange；滚动内容自身不应因
    /// Dock 的每次进度发布而重新计算。只有下方 ProgressHost 负责重绘。
    @Environment(\.bottomDockScrollCoordinator) private var coordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .simultaneousGesture(
                DragGesture(minimumDistance: BottomDockProgressReducer.minimumVerticalSwipeDistance)
                    .onEnded { value in
                        guard BottomDockProgressReducer.terminalProgress(for: value.translation) != nil else { return }
                        withAnimation(BottomDockMotion.animation(reduceMotion: reduceMotion)) {
                            coordinator?.finishInteraction(translation: value.translation)
                        }
                    }
            )
    }
}

/// 将高频进度订阅限制在 Dock 本身。IOSMusicShell、NavigationStack 和当前页面不再
/// 因为用户滚动一两个像素而整体重新求值。
private struct MorphingBottomDockProgressHost: View {
    @ObservedObject var model: AuralisAppModel
    let theme: BuiltInTheme
    let accessory: CollapsedDockAccessory?
    @ObservedObject var coordinator: BottomDockScrollCoordinator
    let onExpand: () -> Void
    let onAssistant: () -> Void
    let onSelect: (AppSection) -> Void

    var body: some View {
        MorphingBottomDock(
            model: model,
            theme: theme,
            accessory: accessory,
            progress: coordinator.collapseProgress,
            onExpand: onExpand,
            onAssistant: onAssistant,
            onSelect: onSelect
        )
    }
}

extension View {
    func reportsBottomDockScroll() -> some View {
        modifier(BottomDockScrollReportingModifier())
    }
}

/// 展开态与紧凑态共用的一套底部组件。所有位置都由 progress 插值计算，
/// 因而播放器、主页和 AI 入口都是同一个 View 在移动和变形，而非两套 UI 交叉淡入淡出。
private struct MorphingBottomDock: View {
    @ObservedObject var model: AuralisAppModel
    let theme: BuiltInTheme
    let accessory: CollapsedDockAccessory?
    let progress: CGFloat
    let onExpand: () -> Void
    let onAssistant: () -> Void
    let onSelect: (AppSection) -> Void
    @Environment(\.colorScheme) private var colorScheme

    private var p: CGFloat { min(max(progress, 0), 1) }
    /// 平滑阶跃：起止柔和、中段移动明确，滚动时不会自行延迟播放。
    private var eased: CGFloat { p * p * (3 - 2 * p) }
    private var chromeFade: CGFloat { smoothstep(from: 0.38, to: 1, value: p) }
    private var itemFade: CGFloat { smoothstep(from: 0.32, to: 0.78, value: p) }

    var body: some View {
        if accessory == nil {
            ExpandedDock(model: model, theme: theme, showsPlayer: false, onSelect: onSelect)
        } else {
            GeometryReader { proxy in
                let height = bottomBarHeight * 2 + dockSpacing + dockBottomPadding
                let horizontalInset: CGFloat = 16
                let fullWidth = max(proxy.size.width - horizontalInset * 2, 0)
                let navCenterY = height - dockBottomPadding - bottomBarHeight / 2
                let playerCenterY = navCenterY - (bottomBarHeight + dockSpacing) * (1 - eased)
                let playerWidth = fullWidth - 128 * eased
                let playerCenterX = proxy.size.width / 2
                let sections = AppSection.compactDockSections
                let itemWidth = fullWidth / CGFloat(sections.count)

                ZStack {
                    // 完整导航栏的玻璃底板在前半程保持完整，后半程收窄并淡出。
                    MorphingGlassCapsule { Color.clear }
                        .frame(width: fullWidth, height: bottomBarHeight)
                        // 玻璃表面固定布局尺寸，只用渲染变换收缩，避免每帧重建材质纹理。
                        .scaleEffect(x: 1 - 0.16 * chromeFade, y: 1, anchor: .center)
                        .position(x: playerCenterX, y: navCenterY)
                        .opacity(1 - chromeFade)

                    // 迷你播放器只有一个实例：从上层下降并持续缩短，最后抵达三件套的中间。
                    if accessory == .player {
                        ZStack {
                            MorphingGlassCapsule { Color.clear }
                                .frame(width: max(playerWidth, bottomBarHeight), height: bottomBarHeight)
                            MiniPlayerContent(
                                model: model,
                                theme: theme,
                                height: bottomBarHeight,
                                skipControlsVisibility: 1 - smoothstep(from: 0.18, to: 0.58, value: p)
                            )
                            .frame(width: max(playerWidth, bottomBarHeight), height: bottomBarHeight)
                            .clipShape(Capsule(style: .continuous))
                        }
                        .frame(width: fullWidth, height: bottomBarHeight)
                        .position(x: playerCenterX, y: playerCenterY)
                        .contentShape(Rectangle())
                        .onTapGesture { model.isNowPlayingPresented = true }
                        .accessibilityElement(children: .contain)
                    }

                    ForEach(sections.indices, id: \.self) { index in
                        morphingItem(
                            section: sections[index],
                            index: index,
                            itemWidth: itemWidth,
                            navCenterY: navCenterY,
                            containerWidth: proxy.size.width
                        )
                    }
                }
                .frame(width: proxy.size.width, height: height, alignment: .bottom)
            }
            .frame(maxWidth: .infinity)
            .frame(height: bottomBarHeight * 2 + dockSpacing + dockBottomPadding)
        }
    }

    private func morphingItem(
        section: AppSection,
        index: Int,
        itemWidth: CGFloat,
        navCenterY: CGFloat,
        containerWidth: CGFloat
    ) -> some View {
        let inset: CGFloat = 16
        let initialX = inset + itemWidth * (CGFloat(index) + 0.5)
        let terminalX: CGFloat
        switch section {
        case .home:
            terminalX = inset + bottomBarHeight / 2
        case .assistant:
            terminalX = containerWidth - inset - bottomBarHeight / 2
        default:
            terminalX = initialX
        }
        let survives = section == .home || section == .assistant
        let x = survives ? interpolate(initialX, terminalX, eased) : initialX
        let width = survives ? interpolate(itemWidth, bottomBarHeight, eased) : itemWidth
        let opacity = survives ? 1 : 1 - itemFade
        let scale = survives ? 1 : 1 - 0.16 * itemFade
        let titleOpacity = 1 - smoothstep(from: 0.08, to: 0.52, value: p)
        let icon = section == .assistant && p > 0.5 ? "sparkles" : section.symbol
        let usesAccentColor = section == model.selectedSection || (section == .home && p >= 0.8)
        let selectedFill = section == model.selectedSection
            ? Color.primary.opacity((colorScheme == .dark ? 0.17 : 0.09) * (1 - chromeFade))
            : Color.clear

        return Button {
            switch section {
            case .home:
                // 完整导航栏仍是原有的“进入首页”；只有收拢完成后，首页圆按钮才承担展开职责。
                if p >= 0.96 {
                    onExpand()
                } else {
                    onSelect(.home)
                }
            case .assistant:
                onAssistant()
            default:
                onSelect(section)
            }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 19, weight: .medium))
                Text(section.title)
                    .font(.caption2)
                    .opacity(titleOpacity)
                    .frame(height: titleOpacity > 0.01 ? nil : 0)
            }
            .foregroundStyle(
                usesAccentColor
                    ? theme.colorTokens.accent.color
                    : theme.colorTokens.secondaryText.color
            )
            .frame(width: width, height: bottomBarHeight)
            .background {
                Capsule(style: .continuous)
                    .fill(selectedFill)
                    .opacity(1 - eased)
                // 前半程仍由完整导航玻璃承载；独立圆形玻璃只在分裂阶段才加入，
                // 可把常见滚动区间的玻璃采样层从四层降到两层。
                if survives, p > 0.44 {
                    MorphingGlassCapsule { Color.clear }
                        .frame(width: bottomBarHeight, height: bottomBarHeight)
                        .opacity(smoothstep(from: 0.44, to: 0.82, value: p))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(opacity)
        .scaleEffect(scale)
        .position(x: x, y: navCenterY)
        .allowsHitTesting(opacity > 0.08)
        .accessibilityLabel(section.title)
    }

    private func interpolate(_ start: CGFloat, _ end: CGFloat, _ amount: CGFloat) -> CGFloat {
        start + (end - start) * amount
    }

    private func smoothstep(from start: CGFloat, to end: CGFloat, value: CGFloat) -> CGFloat {
        let t = min(max((value - start) / (end - start), 0), 1)
        return t * t * (3 - 2 * t)
    }
}

/// 与现有 BottomGlassBarShell 使用相同的液态玻璃材质与描边，只是 frame 由滚动进度连续控制。
private struct MorphingGlassCapsule<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(\.auralisReduceTransparency) private var reduceTransparency

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        Group {
            if reduceTransparency {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.background, in: Capsule(style: .continuous))
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(Color.white.opacity(0.14), lineWidth: 0.5)
                    )
                    .shadow(color: Color.black.opacity(0.05), radius: 4, x: 0, y: 2)
            } else {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .glassEffect(.regular.interactive(), in: Capsule(style: .continuous))
            }
        }
    }
}

/// 展开态：播放附件独立位于四个一级入口上方，和 Apple Music 的常规底栏结构一致。
private struct ExpandedDock: View {
    @ObservedObject var model: AuralisAppModel
    let theme: BuiltInTheme
    let showsPlayer: Bool
    let onSelect: (AppSection) -> Void

    var body: some View {
        VStack(spacing: dockSpacing) {
            if showsPlayer {
                BottomGlassBarShell {
                    MiniPlayerContent(model: model, theme: theme, height: bottomBarHeight)
                }
                .frame(maxWidth: .infinity)
                .frame(height: bottomBarHeight)
                .contentShape(Rectangle())
                .onTapGesture { model.isNowPlayingPresented = true }
                .accessibilityElement(children: .contain)
            }

            BottomGlassBarShell {
                MainTabBarContent(model: model, theme: theme, onSelect: onSelect)
            }
            .frame(maxWidth: .infinity)
            .frame(height: bottomBarHeight)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.bottom, dockBottomPadding)
    }
}

/// 紧凑态：非当前分区收回到首页入口；AI 助手占用原搜索位置。
/// 首页按钮只负责展开完整 Dock，不改变当前首页/音乐库内容，避免意外跳页。
private enum CollapsedDockAccessory: Equatable {
    case player
    case assistant
}

private struct CollapsedDock: View {
    @ObservedObject var model: AuralisAppModel
    let theme: BuiltInTheme
    let accessory: CollapsedDockAccessory
    let onHome: () -> Void
    let onAssistant: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            CircularDockButton(action: onHome) {
                Image(systemName: "house.fill")
                    .font(.system(size: 19, weight: .semibold))
            }
            .foregroundStyle(theme.colorTokens.accent.color)
            .accessibilityLabel(String(localized: "展开首页、音乐库和设置", bundle: .module))

            Group {
                switch accessory {
                case .player:
                    BottomGlassBarShell {
                        CompactMiniPlayerContent(model: model, theme: theme)
                    }
                case .assistant:
                    // AI 页的中间区域由 AssistantView 的真实输入栏占用；
                    // 这里只保留与两端圆形入口等高的透明槽位，不能再叠一层玻璃。
                    Color.clear
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: bottomBarHeight)
            .contentShape(Rectangle())
            .onTapGesture {
                if accessory == .player {
                    model.isNowPlayingPresented = true
                }
            }
            .accessibilityElement(children: accessory == .player ? .contain : .ignore)

            CircularDockButton(action: onAssistant) {
                Image(systemName: "sparkles")
                    .font(.system(size: 21, weight: .semibold))
            }
            .foregroundStyle(theme.colorTokens.primaryText.color)
            .accessibilityLabel(String(localized: "AI 助手", bundle: .module))
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.bottom, dockBottomPadding)
    }
}

/// 紧凑态两端的系统玻璃圆形入口。它们与中间胶囊同高，不再让图标直接悬空。
private struct CircularDockButton<Label: View>: View {
    let action: () -> Void
    @ViewBuilder let label: Label
    @Environment(\.auralisReduceTransparency) private var reduceTransparency

    var body: some View {
        Group {
            if reduceTransparency {
                button
                    .background(.background, in: Circle())
                    .overlay(
                        Circle()
                            .stroke(Color.white.opacity(0.14), lineWidth: 0.5)
                    )
                    .shadow(color: Color.black.opacity(0.05), radius: 4, x: 0, y: 2)
            } else {
                button
                    .glassEffect(.regular.interactive(), in: Circle())
            }
        }
    }

    private var button: some View {
        Button(action: action) {
            label
                .frame(width: bottomBarHeight, height: bottomBarHeight)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

/// AI 助手输入框（iOS，渲染在助手页底部安全区，取代迷你播放条的位置）。
/// 与迷你播放条共用 BottomGlassBarShell、同一高度与材质；点击发送 / 运行时切换为停止。
/// 焦点由调用方通过 `focus` 传入（助手页用 @FocusState 管理），便于页面在发送 / 点击空白时收起键盘。
struct DockAssistantInputBar: View {
    @ObservedObject var model: AuralisAppModel
    /// 运行状态由 AgentCoordinator 发布；不能只经由 model 的计算属性读取，
    /// 否则 Agent 收尾时 model 本身没有 objectWillChange，底部按钮会残留“停止”。
    @ObservedObject var agent: AgentCoordinator
    let theme: BuiltInTheme
    var focus: FocusState<Bool>.Binding

    var body: some View {
        BottomGlassBarShell {
            HStack(alignment: .center, spacing: AuralisSpacing.medium) {
                Image(systemName: "sparkles")
                    .foregroundStyle(theme.colorTokens.accent.color)
                    .frame(width: 22, height: 22)
                TextField("描述你想听的音乐，或让我帮你操作", text: $model.assistantDraft)
                    .textFieldStyle(.plain)
                    .focused(focus)
                    .onSubmit { model.sendAssistantMessage(); focus.wrappedValue = false }
                Button {
                    if agent.isRunning {
                        agent.cancel()
                    } else {
                        model.sendAssistantMessage()
                        focus.wrappedValue = false
                    }
                } label: {
                    Image(systemName: agent.isRunning ? "stop.circle.fill" : "arrow.up.circle.fill")
                        .font(.title2)
                }
                .buttonStyle(HapticPlainButtonStyle())
                .accessibilityLabel(agent.isRunning ? String(localized: "停止", bundle: .module) : String(localized: "发送", bundle: .module))
                .frame(width: 44, height: 44)
            }
            .padding(.horizontal, 12)
        }
        .frame(maxWidth: .infinity)
        .frame(height: bottomBarHeight)
        // 与迷你播放条使用完全相同的左右边距（16pt），保证两态 frame 一致、不铺满屏幕。
        .padding(.horizontal, 16)
    }
}

/// 公共液态玻璃外壳：统一负责背景材质、玻璃折射、圆角、边缘高光与阴影。
/// 迷你播放条与主菜单栏都通过它绘制外轮廓，保证尺寸与材质完全一致。
/// 正常模式由系统 glassEffect 自带边缘与阴影；Reduce Transparency 时改为实色背景 + 细描边。
struct BottomGlassBarShell<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(\.auralisReduceTransparency) private var reduceTransparency

    var body: some View {
        Group {
            if reduceTransparency {
                framedContent
                    .background(.background, in: Capsule(style: .continuous))
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(Color.white.opacity(0.14), lineWidth: 0.5)
                    )
                    .shadow(color: Color.black.opacity(0.05), radius: 4, x: 0, y: 2)
            } else {
                framedContent
                    .glassEffect(.regular.interactive(), in: Capsule(style: .continuous))
            }
        }
    }

    private var framedContent: some View {
        content
            .frame(maxWidth: .infinity, minHeight: bottomBarHeight, maxHeight: bottomBarHeight)
    }
}

/// 主菜单栏内部内容：三个主入口等分宽度，图标与文字居中，
/// 选中高亮仅存在于栏内，不改变栏的整体宽度与高度。
private struct MainTabBarContent: View {
    @ObservedObject var model: AuralisAppModel
    let theme: BuiltInTheme
    let onSelect: (AppSection) -> Void
    @State private var dragOffset: CGFloat = 0
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { proxy in
            let sections = AppSection.compactDockSections
            let itemWidth = proxy.size.width / CGFloat(sections.count)
            // 选中胶囊占满单个 tab 的高度与宽度。首尾时它与外层 Dock 同高、
            // 同半径，圆弧会恰好贴合外框而不是留缝或越界。
            let selectionWidth = itemWidth
            let selectionHeight = proxy.size.height
            let selectedIndex = sections.firstIndex(of: model.selectedSection) ?? 0

            ZStack(alignment: .leading) {
                // 选中块是单一、可拖动的中性胶囊。用动态中性填充而非第二层
                // glassEffect：浅色外观呈图一那种柔和灰色，深色外观保持足够对比。
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(colorScheme == .dark ? 0.17 : 0.09))
                    .shadow(
                        color: Color.black.opacity(colorScheme == .dark ? 0.18 : 0.05),
                        radius: 7, x: 0, y: 3
                    )
                    .frame(width: selectionWidth, height: selectionHeight)
                    // ZStack 在垂直方向默认居中；只需缩小高度，不能再加 y 偏移，
                    // 否则会让胶囊整体下沉而上下留白不对称。
                    .offset(x: CGFloat(selectedIndex) * itemWidth + dragOffset)
                    .allowsHitTesting(false)

                HStack(spacing: 0) {
                    ForEach(sections) { section in
                        Button {
                            withAnimation(.snappy(duration: 0.30, extraBounce: 0.08)) {
                                dragOffset = 0
                                onSelect(section)
                            }
                        } label: {
                            VStack(spacing: 4) {
                                Image(systemName: section.symbol)
                                    .font(.system(size: 19, weight: .medium))
                                Text(section.title)
                                    .font(.caption2)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .contentShape(Rectangle())
                            .foregroundStyle(
                                model.selectedSection == section
                                ? theme.colorTokens.accent.color
                                : theme.colorTokens.secondaryText.color
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .contentShape(Rectangle())
            .simultaneousGesture(tabSwitchGesture(itemWidth: itemWidth, selectedIndex: selectedIndex, sections: sections))
        }
        .frame(maxHeight: .infinity)
    }

    private func tabSwitchGesture(
        itemWidth: CGFloat,
        selectedIndex: Int,
        sections: [AppSection]
    ) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                // 当前手势仅允许挪到相邻入口，避免一次误滑跨过多个 tab。
                let canMoveLeft = selectedIndex < sections.count - 1
                let canMoveRight = selectedIndex > 0
                let requested = value.translation.width
                let limit: ClosedRange<CGFloat>
                if requested < 0, canMoveLeft {
                    limit = -itemWidth ... 0
                } else if requested > 0, canMoveRight {
                    limit = 0 ... itemWidth
                } else {
                    limit = 0 ... 0
                }
                dragOffset = min(max(requested, limit.lowerBound), limit.upperBound)
            }
            .onEnded { value in
                guard abs(value.translation.width) > abs(value.translation.height) else {
                    withAnimation(.snappy(duration: 0.24)) { dragOffset = 0 }
                    return
                }
                let movesToNext = value.translation.width < -itemWidth * 0.32
                let movesToPrevious = value.translation.width > itemWidth * 0.32
                let target: Int
                if movesToNext {
                    target = min(selectedIndex + 1, sections.count - 1)
                } else if movesToPrevious {
                    target = max(selectedIndex - 1, 0)
                } else {
                    target = selectedIndex
                }
                withAnimation(.snappy(duration: 0.32, extraBounce: 0.08)) {
                    onSelect(sections[target])
                    dragOffset = 0
                }
            }
    }
}
#endif

#if !os(iOS)
/// Dock 仅存在于紧凑 iOS 布局；其它平台保留同一调用点但不安装滚动监听。
extension View {
    func reportsBottomDockScroll() -> some View { self }
}
#endif

private struct SectionContent: View {
    let section: AppSection
    @ObservedObject var model: AuralisAppModel
    @ObservedObject var themeStore: ThemeStore
    @Environment(\.bottomDockReservedHeight) private var reservedHeight

    var body: some View {
        page
            .safeAreaInset(edge: .bottom, spacing: 0) {
                // 助手页由 AssistantView 自己管理输入框 + 主菜单栏的避让，这里不重复预留。
                if section != .assistant {
                    Color.clear.frame(height: reservedHeight)
                }
            }
    }

    @ViewBuilder
    private var page: some View {
        switch section {
        case .home:
            HomeView(model: model, theme: themeStore.current)
        case .library:
            LibraryView(model: model, theme: themeStore.current)
        case .assistant:
            AssistantView(model: model, theme: themeStore.current)
        case .search:
            SearchView(model: model, theme: themeStore.current)
        case .settings:
            SettingsView(model: model, themeStore: themeStore)
        }
    }
}

private struct AuralisReduceTransparencyKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var auralisReduceTransparency: Bool {
        get { self[AuralisReduceTransparencyKey.self] }
        set { self[AuralisReduceTransparencyKey.self] = newValue }
    }
}

/// 底部 Dock 真实占用的纵向高度。由各页面读取，作为底部 safe area inset 的统一来源，
/// 让首页 / 设置 / 音乐库 / 搜索 / 助手页用同一套数字避让悬浮控件（macOS 不渲染 Dock，默认 0）。
private struct BottomDockReservedHeightKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    var bottomDockReservedHeight: CGFloat {
        get { self[BottomDockReservedHeightKey.self] }
        set { self[BottomDockReservedHeightKey.self] = newValue }
    }
}

/// 浏览详情弹窗：专辑/艺术家/歌单/收藏/最常听的歌曲清单。
/// 先展示清单，点选单曲才播放；顶部提供「播放全部」作为显式的整列播放入口。
struct BrowseDetailSheet: View {
    private enum PlaylistSortOrder: String, CaseIterable, Identifiable {
        case nameAscending
        case nameDescending
        case recentlyModified

        var id: String { rawValue }
        var title: String {
            switch self {
            case .nameAscending: "名称（A 到 Z）"
            case .nameDescending: "名称（Z 到 A）"
            case .recentlyModified: "最近修改"
            }
        }
    }

    let destination: BrowseDestination
    @ObservedObject var model: AuralisAppModel
    let theme: BuiltInTheme
    let showsCloseButton: Bool
    @State private var isConfirmingDownload = false
    /// 从歌单总览左滑后暂存目标；确认后才会删除服务器歌单。
    @State private var playlistPendingDeletion: Playlist?
    @State private var isManagingPlaylists = false
    @State private var selectedPlaylistIDs: Set<PlaylistID> = []
    @State private var playlistSortOrder: PlaylistSortOrder = .nameAscending
    @State private var confirmsBatchPlaylistDeletion = false
    /// 分类详情改为按需解析：路由只携带身份，这里保存解析结果与错误，避免
    /// 一次性快照进入导航值（索引刷新后可重新解析，读库失败能展示错误与重试）。
    @State private var categoryTracks: [Track]?
    @State private var categoryLoadError: String?
    @State private var isDeletingPlaylists = false
    @Environment(\.dismiss) private var dismiss

    init(
        destination: BrowseDestination,
        model: AuralisAppModel,
        theme: BuiltInTheme,
        showsCloseButton: Bool = true
    ) {
        self.destination = destination
        self.model = model
        self.theme = theme
        self.showsCloseButton = showsCloseButton
    }

    private var tracks: [Track] {
        switch destination {
        case let .album(album):
            return model.catalog.tracks.filter { $0.albumID == album.id }
        case let .artist(artist):
            return model.catalog.tracks.filter { $0.artistID == artist.id }
        case let .playlist(playlist):
            // 优先使用从服务器拉取的完整曲目
            if let loaded = model.playlistTracks[playlist.id], !loaded.isEmpty {
                return loaded
            }
            return playlist.trackIDs.compactMap { id in model.catalog.tracks.first { $0.id == id } }
            case .favorites:
                return model.homeFavoriteTracks
            case .mostPlayed:
                return model.homeMostPlayedTracks
            case .playlists:
                return []
            case let .genre(genre):
                let local = model.tracks(for: genre)
                return local.isEmpty ? (model.genreTracks ?? []) : local
            case .recommendationCategory:
                return categoryTracks ?? []
            case .random:
                return model.randomTracks
            case .recentlyPlayed:
                return model.homeRecentlyPlayedTracks
            case .recentlyAdded:
                return Array(model.homeRecentlyAddedTracks.prefix(200))
            case .longUnplayed:
                return model.homeLongUnplayedTracks
            case .neverPlayed:
                return model.homeNeverPlayedTracks
            case .favoriteRandom:
                return model.homeFavoriteRandomTracks
            case .downloads:
                return model.downloadedTracks
            case .topArtists, .topAlbums:
                return []
        }
    }

    private var title: String {
        switch destination {
        case let .album(album): album.title
        case let .artist(artist): artist.name
        case let .playlist(playlist): playlist.name
        case .playlists: "歌单"
        case .favorites: "收藏"
        case .mostPlayed: "最常听"
        case let .genre(genre): GenreLocalization.displayName(for: genre.name)
        case let .recommendationCategory(category): categoryDisplayName(category)
        case .random: "随机音乐"
        case .recentlyPlayed: "最近播放"
        case .recentlyAdded: "最近添加"
        case .longUnplayed: "很久没听"
        case .neverPlayed: "从未播放"
        case .favoriteRandom: "收藏里随便听"
        case .topArtists: "常听艺术家"
        case .topAlbums: "常听专辑"
        case .downloads: "下载"
        }
    }

    private var subtitle: String {
        switch destination {
        case let .album(album): "\(album.artistName) · \(tracks.count) 首"
        case .artist: "\(tracks.count) 首歌曲"
        case let .playlist(playlist): playlist.comment ?? "\(tracks.count) 首歌曲"
        case .playlists: "\(model.catalog.playlists.count) 个歌单"
        case .favorites: "\(tracks.count) 首喜爱的歌曲"
        case .mostPlayed: "按你的播放次数排序"
        case let .genre(genre): "\(tracks.count) 首 · 按流派「\(GenreLocalization.displayName(for: genre.name))」筛选"
        case let .recommendationCategory(category): "\(tracks.count) 首 · 按分类「\(categoryDisplayName(category))」筛选"
        case .random: "点右上角「换一批」可重新随机"
        case .recentlyPlayed: "\(tracks.count) 首 · 最近播放过的歌曲"
        case .recentlyAdded: "\(tracks.count) 首 · 最近同步进来的歌曲"
        case .longUnplayed: "\(tracks.count) 首 · 播放过但最近没听的歌曲"
        case .neverPlayed: "\(tracks.count) 首 · 还没播放过的歌曲"
        case .favoriteRandom: "点右上角「换一批」可重新随机"
        case .topArtists: "按真实播放次数统计的艺术家"
        case .topAlbums: "按真实播放次数统计的专辑"
        case .downloads: "\(tracks.count) 首 · 已下载到本地的歌曲"
        }
    }

    private var artworkKey: String? {
        switch destination {
        case let .album(album): album.artworkKey
        case let .artist(artist): artist.artworkKey
        default: nil
        }
    }

    private func categoryDisplayName(_ category: RecommendationIndexV2Category) -> String {
        let dimension: String
        switch category.dimension {
        case "mood": dimension = "情绪"
        case "scene": dimension = "场景"
        case "vocal": dimension = "人声"
        case "texture": dimension = "质感"
        case "style": dimension = "风格"
        case "energy": dimension = "能量"
        case "tempo": dimension = "速度"
        case "acousticness": dimension = "原声感"
        case "danceability": dimension = "舞动性"
        default: dimension = category.dimension
        }
        let value = ["energy": 10, "tempo": 5, "acousticness": 5, "danceability": 5][category.dimension]
            .map { "\(category.value)/\($0)" } ?? category.value
        return "\(dimension) · \(value)"
    }

    var body: some View {
        Group {
            if showsCloseButton {
                // 作为 sheet 呈现时需要自己的导航容器。
                NavigationStack { navigationContent }
            } else {
                // 作为 navigationDestination 推入时复用外层容器，不能嵌套第二个
                // NavigationStack，否则系统返回手势和后续 NavigationLink 会失效。
                navigationContent
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 480)
        #endif
        .onAppear {
            if case let .playlist(playlist) = destination {
                model.loadPlaylistTracks(playlistID: playlist.id)
            } else if case let .genre(genre) = destination, model.tracks(for: genre).isEmpty {
                // 本地按流派筛选为空时，从服务器按流派拉取真实歌曲
                // （Navidrome 等服务器 getGenres 常为空，但按流派列专辑可用）。
                model.loadGenreTracks(genre)
            } else if case let .recommendationCategory(category) = destination {
                loadRecommendationCategoryTracks(category)
            }
        }
        .confirmationDialog(
            "下载 \(tracks.count) 首歌曲？",
            isPresented: $isConfirmingDownload,
            titleVisibility: .visible
        ) {
            Button(String(localized: "开始下载", bundle: .module)) {
                model.downloadAll(tracks)
            }
            Button(String(localized: "取消", bundle: .module), role: .cancel) {}
        } message: {
            Text("预计约 \(estimatedSizeMB(tracks.count)) MB，下载到本地后可离线播放。已下载的歌曲会自动跳过。")
        }
        .confirmationDialog(
            "删除选中的 \(selectedPlaylistIDs.count) 个歌单？",
            isPresented: $confirmsBatchPlaylistDeletion,
            titleVisibility: .visible
        ) {
            Button(String(localized: "删除", bundle: .module), role: .destructive) { deleteSelectedPlaylists() }
            Button(String(localized: "取消", bundle: .module), role: .cancel) {}
        } message: {
            Text(String(localized: "选中的歌单会同时从音乐服务器和本地目录删除，歌曲文件不会被删除。", bundle: .module))
        }
    }

    private var navigationContent: some View {
        content
            .navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    if isRandomDestination {
                        Button {
                            regenerateCurrentSample()
                        } label: {
                            Label(String(localized: "换一批", bundle: .module), systemImage: "arrow.clockwise")
                        }
                    }
                }
                if isPlaylistDestination {
                    ToolbarItem(placement: .primaryAction) {
                        playlistManagementToolbar
                    }
                }
                if showsCloseButton {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(String(localized: "关闭", bundle: .module)) { dismiss() }
                    }
                }
            }
    }

    private func estimatedSizeMB(_ count: Int) -> Int {
        // 按平均 8 MB/首估算（原始 FLAC 更大、MP3 更小），仅用于下载前容量提示。
        Int((Double(count) * 8 / 1024).rounded())
    }

    private var isPlaylistDestination: Bool {
        if case .playlists = destination { return true }
        return false
    }

    @ViewBuilder
    private var playlistManagementToolbar: some View {
        if isManagingPlaylists {
            HStack(spacing: AuralisSpacing.small) {
                Button(selectedPlaylistIDs.count == sortedPlaylists.count ? String(localized: "取消全选", bundle: .module) : String(localized: "全选", bundle: .module)) {
                    if selectedPlaylistIDs.count == sortedPlaylists.count {
                        selectedPlaylistIDs.removeAll()
                    } else {
                        selectedPlaylistIDs = Set(sortedPlaylists.map(\.id))
                    }
                }
                .disabled(sortedPlaylists.isEmpty || isDeletingPlaylists)
                Button(role: .destructive) {
                    confirmsBatchPlaylistDeletion = true
                } label: {
                    Image(systemName: "trash")
                }
                .disabled(selectedPlaylistIDs.isEmpty || isDeletingPlaylists)
                Button(String(localized: "完成", bundle: .module)) {
                    selectedPlaylistIDs.removeAll()
                    isManagingPlaylists = false
                }
                .disabled(isDeletingPlaylists)
            }
        } else {
            Menu {
                Button {
                    isManagingPlaylists = true
                } label: {
                    Label(String(localized: "批量删除", bundle: .module), systemImage: "checkmark.circle")
                }
                Menu("排序") {
                    ForEach(PlaylistSortOrder.allCases) { order in
                        Button {
                            playlistSortOrder = order
                        } label: {
                            Label(order.title, systemImage: playlistSortOrder == order ? "checkmark" : "")
                        }
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel(String(localized: "歌单管理与排序", bundle: .module))
        }
    }

    private func deleteSelectedPlaylists() {
        let ids = selectedPlaylistIDs
        guard !ids.isEmpty else { return }
        isDeletingPlaylists = true
        Task {
            for id in ids {
                _ = await model.deletePlaylist(id: id)
            }
            selectedPlaylistIDs.removeAll()
            isDeletingPlaylists = false
            isManagingPlaylists = false
        }
    }

    private func loadRecommendationCategoryTracks(_ category: RecommendationIndexV2Category) {
        guard categoryTracks == nil, categoryLoadError == nil else { return }
        categoryTracks = []
        Task {
            do {
                let tracks = try await model.catalogCoordinator.store.recommendationIndexV2Tracks(
                    serverID: model.catalog.activeAccount?.id,
                    dimension: category.dimension,
                    value: category.value
                )
                categoryTracks = tracks
            } catch {
                categoryLoadError = "读取分类歌曲失败：\(error.localizedDescription)"
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if case .playlists = destination {
            playlistList
        } else if case .topArtists = destination {
            artistList
        } else if case .topAlbums = destination {
            albumList
        } else if case .recommendationCategory = destination {
            if let categoryLoadError {
                AuralisEmptyState(
                    icon: "exclamationmark.triangle",
                    title: "读取分类失败",
                    message: categoryLoadError,
                    colors: theme.colorTokens
                )
            } else if categoryTracks == nil {
                ProgressView("正在读取分类歌曲…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if tracks.isEmpty {
                AuralisEmptyState(
                    icon: "music.note",
                    title: "暂无歌曲",
                    message: "这个分类里暂时没有歌曲。",
                    colors: theme.colorTokens
                )
            } else {
                trackList
            }
        } else if isGenreLoading {
            ProgressView("正在从服务器加载「\(currentGenreName)」歌曲…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if tracks.isEmpty {
            AuralisEmptyState(
                icon: "music.note",
                title: "暂无歌曲",
                message: emptyMessage,
                colors: theme.colorTokens
            )
        } else {
            trackList
        }
    }

    /// 流派详情正在从服务器加载（本地筛选为空且尚未返回结果）。
    private var isGenreLoading: Bool {
        if case let .genre(genre) = destination,
           model.tracks(for: genre).isEmpty,
           model.loadingGenre?.name == genre.name,
           model.genreTracks == nil {
            return true
        }
        return false
    }

    private var currentGenreName: String {
        if case let .genre(genre) = destination { return genre.name }
        return ""
    }

    private var emptyMessage: String {
        switch destination {
        case .favorites: "在播放页或歌曲菜单中点心形收藏后，会出现在这里。"
        case .mostPlayed: "播放过的歌曲会按次数统计在这里。"
        case .longUnplayed: "播放过的歌曲会先出现在「最近播放」，过一段时间没听就会回到这里。"
        case .neverPlayed: "还没有播放记录时，这里暂时为空。"
        case .favoriteRandom: "收藏里的歌曲会随机出现在这里。"
        case .downloads: "下载到本地的歌曲会出现在这里。"
        case .topArtists: "播放过的歌曲会按艺术家统计在这里。"
        case .topAlbums: "播放过的歌曲会按专辑统计在这里。"
        default: "这个清单里暂时没有歌曲。"
        }
    }

    private var trackList: some View {
        List {
            Section {
                HStack(spacing: AuralisSpacing.medium) {
                    ArtworkView(title: title, artworkKey: artworkKey, colors: theme.colorTokens, size: 88)
                    VStack(alignment: .leading, spacing: AuralisSpacing.xSmall) {
                        Text(title)
                            .font(.headline)
                            .foregroundStyle(theme.colorTokens.primaryText.color)
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(theme.colorTokens.secondaryText.color)
                        HStack(spacing: AuralisSpacing.small) {
                            Button {
                                playAll()
                            } label: {
                                Label(String(localized: "播放全部", bundle: .module), systemImage: "play.fill")
                                    .fixedSize(horizontal: true, vertical: false)
                            }
                            .buttonStyle(HapticProminentButtonStyle())
                            .disabled(tracks.isEmpty)
                            Button {
                                isConfirmingDownload = true
                            } label: {
                                Label(String(localized: "下载", bundle: .module), systemImage: "arrow.down.circle")
                                    .fixedSize(horizontal: true, vertical: false)
                            }
                            .buttonStyle(HapticBorderedButtonStyle())
                            .disabled(tracks.isEmpty)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, AuralisSpacing.xSmall)
            }
            Section(String(localized: "歌曲", bundle: .module)) {
                ForEach(tracks) { track in
                    Button {
                        model.queue = model.uniquedTracks(tracks)
                        model.selectAndPlay(track)
                        dismiss()
                    } label: {
                        TrackRow(track: track, isCurrent: track.isSame(as: model.currentTrack), theme: theme)
                            .contentShape(Rectangle())
                    }
                        .buttonStyle(HapticPlainButtonStyle())
                        .accessibilityLabel(String(localized: "播放《\(track.title)》，艺术家 \(track.artistName)", bundle: .module))
                }
            }
        }
        .listStyle(.plain)
    }

    /// 歌单总览：点选进入歌单内的歌曲清单。
    private var playlistList: some View {
        List(sortedPlaylists) { playlist in
            if isManagingPlaylists {
                Button {
                    if selectedPlaylistIDs.contains(playlist.id) {
                        selectedPlaylistIDs.remove(playlist.id)
                    } else {
                        selectedPlaylistIDs.insert(playlist.id)
                    }
                } label: {
                    playlistRow(playlist, showsSelection: true)
                }
                .buttonStyle(.plain)
            } else {
                NavigationLink {
                    PlaylistTracksView(playlist: playlist, model: model, theme: theme)
                } label: {
                    playlistRow(playlist, showsSelection: false)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        playlistPendingDeletion = playlist
                    } label: {
                        Label(String(localized: "删除", bundle: .module), systemImage: "trash")
                    }
                }
            }
        }
        .listStyle(.plain)
        .confirmationDialog(
            playlistPendingDeletion.map { "删除歌单「\($0.name)」？" } ?? "删除歌单？",
            isPresented: Binding(
                get: { playlistPendingDeletion != nil },
                set: { if !$0 { playlistPendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(String(localized: "删除", bundle: .module), role: .destructive) {
                guard let playlist = playlistPendingDeletion else { return }
                playlistPendingDeletion = nil
                Task { _ = await model.deletePlaylist(id: playlist.id) }
            }
            Button(String(localized: "取消", bundle: .module), role: .cancel) { playlistPendingDeletion = nil }
        } message: {
            Text(String(localized: "该歌单会同时从音乐服务器和本地目录删除，歌曲文件不会被删除。", bundle: .module))
        }
        .alert(
            "无法删除歌单",
            isPresented: Binding(
                get: { model.playlistDeletionError != nil },
                set: { if !$0 { model.clearPlaylistDeletionError() } }
            )
        ) {
            Button(String(localized: "知道了", bundle: .module), role: .cancel) { model.clearPlaylistDeletionError() }
        } message: {
            Text(model.playlistDeletionError ?? "")
        }
    }

    private var sortedPlaylists: [Playlist] {
        switch playlistSortOrder {
        case .nameAscending:
            model.catalog.playlists.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .nameDescending:
            model.catalog.playlists.sorted { $0.name.localizedStandardCompare($1.name) == .orderedDescending }
        case .recentlyModified:
            model.catalog.playlists.sorted {
                ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast)
            }
        }
    }

    private func playlistRow(_ playlist: Playlist, showsSelection: Bool) -> some View {
        HStack(spacing: AuralisSpacing.medium) {
            if showsSelection {
                Image(systemName: selectedPlaylistIDs.contains(playlist.id) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selectedPlaylistIDs.contains(playlist.id) ? theme.colorTokens.accent.color : theme.colorTokens.secondaryText.color)
            }
            if let coverKey = playlistCoverKey(model, playlist) {
                ArtworkView(title: playlist.name, artworkKey: coverKey, colors: theme.colorTokens, size: 40, cornerRadius: 8)
            } else {
                Image(systemName: "music.note.list")
                    .font(.title3)
                    .foregroundStyle(theme.colorTokens.accent.color)
                    .frame(width: 40, height: 40)
                    .background(theme.colorTokens.surface.color)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            Text(playlist.name)
                .foregroundStyle(theme.colorTokens.primaryText.color)
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    /// 随机类浏览页（随机音乐 / 收藏里随便听）：右上角「换一批」本地重采样，不发网络请求。
    private var isRandomDestination: Bool {
        if case .random = destination { return true }
        if case .favoriteRandom = destination { return true }
        return false
    }

    private func regenerateCurrentSample() {
        if case .favoriteRandom = destination {
            model.regenerateFavoriteRandomMusic()
        } else {
            model.regenerateRandomMusic()
        }
    }

    /// 常听艺术家列表：按真实播放次数降序，点选进入艺术家详情。
    private var artistList: some View {
        List(model.homeTopArtists) { artist in
            NavigationLink {
                BrowseDetailSheet(
                    destination: .artist(artist),
                    model: model,
                    theme: theme,
                    showsCloseButton: false
                )
            } label: {
                HStack(spacing: AuralisSpacing.medium) {
                    ArtworkView(title: artist.name, artworkKey: artist.artworkKey, colors: theme.colorTokens, size: 44, cornerRadius: AuralisRadius.small)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(artist.name)
                            .foregroundStyle(theme.colorTokens.primaryText.color)
                        Text("\(model.homeTopArtistPlayCounts[artist.id] ?? 0) 次播放")
                            .font(.caption)
                            .foregroundStyle(theme.colorTokens.secondaryText.color)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(HapticPlainButtonStyle())
        }
        .listStyle(.plain)
    }

    /// 常听专辑列表：按真实播放次数降序，点选进入专辑详情。
    private var albumList: some View {
        List(model.homeTopAlbums) { album in
            NavigationLink {
                BrowseDetailSheet(
                    destination: .album(album),
                    model: model,
                    theme: theme,
                    showsCloseButton: false
                )
            } label: {
                HStack(spacing: AuralisSpacing.medium) {
                    ArtworkView(title: album.title, artworkKey: album.artworkKey, colors: theme.colorTokens, size: 44, cornerRadius: AuralisRadius.small)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(album.title)
                            .foregroundStyle(theme.colorTokens.primaryText.color)
                        Text(album.artistName)
                            .font(.caption)
                            .foregroundStyle(theme.colorTokens.secondaryText.color)
                            .lineLimit(1)
                        Text("\(model.homeTopAlbumPlayCounts[album.id] ?? 0) 次播放")
                            .font(.caption)
                            .foregroundStyle(theme.colorTokens.secondaryText.color)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(HapticPlainButtonStyle())
        }
        .listStyle(.plain)
    }

    private func playAll() {
        guard let first = tracks.first else { return }
        model.queue = tracks
        model.selectAndPlay(first)
        dismiss()
    }
}

/// 歌单内的歌曲清单（从歌单总览推入）。
/// getPlaylists（复数）只返回歌单元数据不含曲目，必须调 getPlaylist（单数）才有完整 entry。
private struct PlaylistTracksView: View {
    let playlist: Playlist
    @ObservedObject var model: AuralisAppModel
    let theme: BuiltInTheme

    private var tracks: [Track] {
        // 优先使用从服务器拉取的完整曲目；回退到 catalog 中已缓存的匹配
        if let loaded = model.playlistTracks[playlist.id], !loaded.isEmpty {
            return loaded
        }
        return playlist.trackIDs.compactMap { id in model.catalog.tracks.first { $0.id == id } }
    }

    private var isLoading: Bool {
        model.loadingPlaylistIDs.contains(playlist.id)
    }

    @State private var isRenaming = false
    @State private var renameText = ""
    @State private var isDeleting = false
    @State private var isDuplicating = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if isLoading && tracks.isEmpty {
                ProgressView("正在加载歌单…")
            } else if tracks.isEmpty {
                AuralisEmptyState(
                    icon: "music.note.list",
                    title: "歌单暂无歌曲",
                    message: "服务器上这个歌单里还没有添加歌曲。",
                    colors: theme.colorTokens
                )
            } else {
                List {
                    ForEach(tracks) { track in
                        Button {
                            model.queue = model.uniquedTracks(tracks)
                            model.selectAndPlay(track)
                        } label: {
                            TrackRow(track: track, isCurrent: track.isSame(as: model.currentTrack), theme: theme)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(HapticPlainButtonStyle())
                        .accessibilityLabel(String(localized: "播放《\(track.title)》，艺术家 \(track.artistName)", bundle: .module))
                    }
                    .onDelete { offsets in
                        // 滑动删除：把服务器歌单里的对应曲目移除（同步到服务器 + 本地目录）。
                        let indices = Array(offsets)
                        Task { _ = await model.removeFromPlaylist(id: playlist.id, atIndices: indices) }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle(playlist.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        renameText = playlist.name
                        isRenaming = true
                    } label: { Label(String(localized: "重命名", bundle: .module), systemImage: "pencil") }
                    Button {
                        isDuplicating = true
                        Task {
                            _ = await model.duplicatePlaylist(id: playlist.id)
                            isDuplicating = false
                        }
                    } label: { Label(isDuplicating ? String(localized: "复制中…", bundle: .module) : String(localized: "复制歌单", bundle: .module), systemImage: "plus.square.on.square") }
                    .disabled(isDuplicating)
                    Button {
                        Task { await model.removeDuplicateSongs(from: playlist.id) }
                    } label: { Label(String(localized: "去重歌曲", bundle: .module), systemImage: "sparkles") }
                    Button(role: .destructive) {
                        isDeleting = true
                    } label: { Label(String(localized: "删除歌单", bundle: .module), systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel(String(localized: "歌单操作", bundle: .module))
            }
        }
        .alert(String(localized: "重命名歌单", bundle: .module), isPresented: $isRenaming) {
            TextField("歌单名称", text: $renameText)
            Button(String(localized: "保存", bundle: .module)) {
                let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty {
                    Task { _ = await model.renamePlaylist(id: playlist.id, to: name) }
                }
            }
            Button(String(localized: "取消", bundle: .module), role: .cancel) {}
        } message: {
            Text(String(localized: "修改将同步到服务器。", bundle: .module))
        }
        .confirmationDialog("删除歌单「\(playlist.name)」？", isPresented: $isDeleting, titleVisibility: .visible) {
            Button(String(localized: "删除", bundle: .module), role: .destructive) {
                Task {
                    _ = await model.deletePlaylist(id: playlist.id)
                    dismiss()
                }
            }
            Button(String(localized: "取消", bundle: .module), role: .cancel) {}
        } message: {
            Text(String(localized: "服务器上的歌单也会被删除，此操作不可撤销。", bundle: .module))
        }
        .onAppear { model.loadPlaylistTracks(playlistID: playlist.id) }
    }
}


/// 歌单封面：取歌单内第一首歌曲的封面（同一专辑多首歌曲共享封面）。
@MainActor
private func playlistCoverKey(_ model: AuralisAppModel, _ playlist: Playlist) -> String? {
    guard let firstID = playlist.trackIDs.first else { return nil }
    return model.catalog.tracks.first { $0.id == firstID }?.artworkKey
}
