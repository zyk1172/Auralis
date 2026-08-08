import DesignSystem
import SwiftUI
import ThemeEngine

/// 首页布局编辑页：分「快捷入口」「内容模块」两区，每行「模块名称 + 显示开关 + 拖动手柄」。
/// - 原生拖动排序（List + ForEach + EditMode + onMove，不引入第三方拖拽库）；
/// - 改动即时生效并持久化到 UserDefaults（HomeLayoutStore），「完成」仅关闭本页；
/// - 底部「恢复默认布局」带确认弹窗，只重置首页布局偏好，不删任何数据 / 缓存 / 播放记录。
struct HomeLayoutEditView: View {
    @ObservedObject var model: AuralisAppModel
    let theme: BuiltInTheme
    @Environment(\.dismiss) private var dismiss
    @State private var isConfirmingReset = false

    private var colors: ThemeColors { theme.colorTokens }

    var body: some View {
        NavigationStack {
            List {
                moduleSection(
                    group: .quickEntry,
                    prefs: model.homeLayout.quickEntries
                ) { from, to in
                    model.moveHomeModule(in: .quickEntry, fromOffsets: from, toOffset: to)
                }
                moduleSection(
                    group: .content,
                    prefs: model.homeLayout.contentModules
                ) { from, to in
                    model.moveHomeModule(in: .content, fromOffsets: from, toOffset: to)
                }
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
            .confirmationDialog(
                "恢复默认布局？",
                isPresented: $isConfirmingReset,
                titleVisibility: .visible
            ) {
                Button("恢复默认", role: .destructive) {
                    model.resetHomeLayout()
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("仅重置首页模块的显示与排序，不会删除任何歌曲、缓存或播放记录。")
            }
        }
    }

    /// 一区（快捷入口 / 内容模块）：Section 标题 + 可拖动排序的行。
    private func moduleSection(
        group: HomeModuleGroup,
        prefs: [HomeModulePreference],
        onMove: @escaping (IndexSet, Int) -> Void
    ) -> some View {
        Section(group.title) {
            ForEach(prefs) { pref in
                moduleRow(pref: pref)
            }
            .onMove(perform: onMove)
        }
    }

    private func moduleRow(pref: HomeModulePreference) -> some View {
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
            Toggle("", isOn: visibilityBinding(for: pref))
                .labelsHidden()
                .tint(colors.accent.color)
        }
        .padding(.vertical, 2)
    }

    /// 开关直接写回模型并持久化（实时生效；本页关闭不改变任何配置）。
    private func visibilityBinding(for pref: HomeModulePreference) -> Binding<Bool> {
        Binding(
            get: { pref.isVisible },
            set: { model.setHomeModuleVisible(pref.moduleID, isVisible: $0) }
        )
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
