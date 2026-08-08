import DesignSystem
import SwiftUI
import ThemeEngine

/// 首页布局编辑页：分「快捷入口」「内容模块」两区，每行「模块名称 + 显示开关 + 拖动手柄」。
/// - 原生拖动排序（List + ForEach + EditMode + onMove，不引入第三方拖拽库）；
/// - 改动即时生效并持久化到 UserDefaults（HomeLayoutStore），「完成」仅关闭本页；
/// - 底部「恢复默认布局」带确认弹窗，只重置首页布局偏好，不删任何数据 / 缓存 / 播放记录。
///
/// 崩溃修复说明：List 的 ForEach 以本视图的 `@State` 本地数组为唯一数据源，
/// `onMove` / 开关 / 恢复默认都先改本地数组、再整组提交给模型。若直接让
/// ForEach 读 `model.homeLayout`（@Published），拖动时模型重渲染会与
/// SwiftUI UpdateCoalescingCollectionView 的移动事务竞争，触发
/// "attempt to move index path … that does not exist" 崩溃。
struct HomeLayoutEditView: View {
    @ObservedObject var model: AuralisAppModel
    let theme: BuiltInTheme
    @Environment(\.dismiss) private var dismiss
    @State private var isConfirmingReset = false
    @State private var quickEntries: [HomeModulePreference] = []
    @State private var contentModules: [HomeModulePreference] = []

    private var colors: ThemeColors { theme.colorTokens }

    var body: some View {
        NavigationStack {
            List {
                moduleSection(group: .quickEntry, prefs: $quickEntries)
                moduleSection(group: .content, prefs: $contentModules)
            }
            #if os(iOS)
            .listStyle(.insetGrouped)
            // iOS 下激活原生 EditMode 以显示拖动手柄（List + onMove 原生拖动排序）。
            .environment(\.editMode, .constant(.active))
            #else
            .listStyle(.inset)
            #endif
            .scrollContentBackground(.hidden)
            .background(colors.background.color)
            .navigationTitle("编辑首页")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                resetBar
            }
            .onAppear {
                quickEntries = model.homeLayout.quickEntries
                contentModules = model.homeLayout.contentModules
            }
            .confirmationDialog(
                "恢复默认布局？",
                isPresented: $isConfirmingReset,
                titleVisibility: .visible
            ) {
                Button("恢复默认", role: .destructive) {
                    let defaults = HomeModuleRegistry.defaultPreference()
                    quickEntries = defaults.quickEntries
                    contentModules = defaults.contentModules
                    model.resetHomeLayout()
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("仅重置首页模块的显示与排序，不会删除任何歌曲、缓存或播放记录。")
            }
        }
    }

    /// 一区（快捷入口 / 内容模块）：Section 标题 + 可拖动排序的行。
    /// `prefs` 是 @State 绑定：onMove 直接改本地数组（Array.move 语义），再整组提交模型。
    private func moduleSection(
        group: HomeModuleGroup,
        prefs: Binding<[HomeModulePreference]>
    ) -> some View {
        Section(group.title) {
            ForEach(prefs.wrappedValue) { pref in
                moduleRow(pref: pref, group: group)
            }
            .onMove { from, to in
                prefs.wrappedValue.move(fromOffsets: from, toOffset: to)
                persist()
            }
        }
    }

    private func moduleRow(pref: HomeModulePreference, group: HomeModuleGroup) -> some View {
        HStack(spacing: AuralisSpacing.medium) {
            if let module = HomeModuleRegistry.module(forID: pref.moduleID) {
                Image(systemName: module.icon)
                    .font(.body)
                    .foregroundStyle(colors.accent.color)
                    .frame(width: 28)
                Text(module.title)
                    .font(.body)
                    .foregroundStyle(colors.primaryText.color)
            } else {
                Text(pref.moduleID)
                    .font(.body)
                    .foregroundStyle(colors.secondaryText.color)
            }
            Spacer()
            Toggle("", isOn: visibilityBinding(for: pref, group: group))
                .labelsHidden()
                .tint(colors.accent.color)
        }
        .padding(.vertical, 2)
    }

    /// 开关直接写回本地数组 + 模型（实时生效；本页关闭不改变任何配置）。
    private func visibilityBinding(for pref: HomeModulePreference, group: HomeModuleGroup) -> Binding<Bool> {
        Binding(
            get: { pref.isVisible },
            set: { isVisible in
                switch group {
                case .quickEntry:
                    if let index = quickEntries.firstIndex(where: { $0.moduleID == pref.moduleID }) {
                        quickEntries[index].isVisible = isVisible
                    }
                case .content:
                    if let index = contentModules.firstIndex(where: { $0.moduleID == pref.moduleID }) {
                        contentModules[index].isVisible = isVisible
                    }
                }
                model.setHomeModuleVisible(pref.moduleID, isVisible: isVisible)
            }
        )
    }

    /// 把本地（已排序 / 已开关）的布局整组提交给模型并持久化。
    private func persist() {
        model.replaceHomeLayout(quickEntries: quickEntries, contentModules: contentModules)
    }

    private var resetBar: some View {
        Button(role: .destructive) {
            isConfirmingReset = true
        } label: {
            Text("恢复默认布局")
                .font(.body.weight(.medium))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(HapticDestructiveButtonStyle())
        .padding(.horizontal, AuralisSpacing.large)
        .padding(.top, AuralisSpacing.medium)
        .padding(.bottom, AuralisSpacing.medium)
        .background(colors.background.color)
    }
}
