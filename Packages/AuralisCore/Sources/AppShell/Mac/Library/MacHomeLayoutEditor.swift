#if os(macOS)
import SwiftUI
import ThemeEngine

/// Mac 首页编辑器：只编辑「内容模块」。
/// - Mac 首页只渲染 contentModules（quickEntries 在 Mac 不显示，不再提供编辑）；
/// - 用明确的 Toggle + 上移/下移按钮（不依赖 iOS EditMode/onMove），保证功能可靠；
/// - Sheet 固定 560×600，避免复用 iOS HomeLayoutEditView 时 List 无 intrinsic height
///   被压成只有标题的矮 sheet。
struct MacHomeLayoutEditor: View {
    @ObservedObject var model: AuralisAppModel
    let theme: BuiltInTheme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(String(localized: "编辑首页", bundle: .module))
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Button(String(localized: "恢复默认布局", bundle: .module)) {
                    model.homeStore.resetLayout()
                }
                Button(String(localized: "完成", bundle: .module)) {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Divider()
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(contentModules.enumerated()), id: \.element.id) { index, pref in
                        row(pref, index: index)
                        if index < contentModules.count - 1 {
                            Divider().padding(.leading, 48)
                        }
                    }
                }
            }
        }
        .frame(width: 560, height: 600)
        .background(theme.colorTokens.background.color)
    }

    private var contentModules: [HomeModulePreference] {
        model.homeLayout.contentModules
    }

    private func module(_ pref: HomeModulePreference) -> HomeModule? {
        HomeModuleRegistry.module(forID: pref.moduleID)
    }

    private func row(_ pref: HomeModulePreference, index: Int) -> some View {
        let module = module(pref)
        return HStack(spacing: 10) {
            Image(systemName: module?.icon ?? "square.grid.2x2")
                .frame(width: 22)
                .foregroundStyle(.secondary)
            Text(module?.title ?? pref.moduleID)
                .frame(maxWidth: .infinity, alignment: .leading)
            Toggle("", isOn: Binding(
                get: { pref.isVisible },
                set: { model.homeStore.setModuleVisible(pref.moduleID, isVisible: $0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            Button {
                move(index, by: -1)
            } label: {
                Image(systemName: "arrow.up")
            }
            .buttonStyle(.borderless)
            .disabled(index == 0)
            .help("上移")
            Button {
                move(index, by: 1)
            } label: {
                Image(systemName: "arrow.down")
            }
            .buttonStyle(.borderless)
            .disabled(index == contentModules.count - 1)
            .help("下移")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }

    /// 上移 / 下移：直接用 HomeStore 的 IndexSet move 语义（目标在源之后需 +1）。
    private func move(_ index: Int, by delta: Int) {
        let target = index + delta
        guard contentModules.indices.contains(target) else { return }
        model.homeStore.moveModule(
            in: .content,
            fromOffsets: IndexSet([index]),
            toOffset: delta > 0 ? target + 1 : target
        )
    }
}
#endif