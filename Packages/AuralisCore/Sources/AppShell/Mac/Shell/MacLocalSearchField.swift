#if os(macOS)
import SwiftUI

/// 纯 SwiftUI 本地搜索框（不使用系统 `.searchable`）。
///
/// 原因：macOS 27 Beta / Xcode 27 Beta 中，`NavigationSplitView` detail 内使用
/// `.searchable` 会在布局事务中触发 SwiftUI 内部 `SearchNavigationSplitViewCandidateKey`
/// 的 Preference reduce 强解包崩溃（`_assertionFailure` + SIGTRAP，见
/// `Docs/MacPlatformAudit.md` 的「NavigationSplitView + searchable 崩溃」条目）。
///
/// 该组件用普通 TextField 实现同等搜索能力（图标 + 清除按钮 + 提交），
/// 不注册任何系统搜索候选，从而彻底避开崩溃路径。页面内「本地搜索」语义不变。
struct MacLocalSearchField: View {
    @Binding var text: String
    var prompt: String = "搜索"
    var onSubmit: () -> Void = {}
    /// 可选外部 FocusState：⌘F 等场景由父视图持有并主动聚焦。
    var focus: FocusState<Bool>.Binding? = nil

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            field
                .textFieldStyle(.plain)
                .onSubmit(onSubmit)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("清除")
                .accessibilityLabel("清除搜索")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(.quaternary.opacity(0.45))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(.separator.opacity(0.4), lineWidth: 0.5)
        }
        .frame(maxWidth: 280)
        .accessibilityLabel(prompt)
    }

    @ViewBuilder
    private var field: some View {
        if let focus {
            TextField(prompt, text: $text)
                .focused(focus)
        } else {
            TextField(prompt, text: $text)
        }
    }
}

/// 页面顶部搜索栏容器：本地搜索框 + 可选尾随控件，统一各资料库页面排版。
struct MacPageSearchHeader<Accessory: View>: View {
    @Binding var text: String
    var prompt: String
    var onSubmit: () -> Void
    var focus: FocusState<Bool>.Binding?
    private let accessory: Accessory

    init(
        text: Binding<String>,
        prompt: String,
        onSubmit: @escaping () -> Void = {},
        focus: FocusState<Bool>.Binding? = nil,
        @ViewBuilder accessory: () -> Accessory = { EmptyView() }
    ) {
        _text = text
        self.prompt = prompt
        self.onSubmit = onSubmit
        self.focus = focus
        self.accessory = accessory()
    }

    var body: some View {
        HStack(spacing: 12) {
            MacLocalSearchField(text: $text, prompt: prompt, onSubmit: onSubmit, focus: focus)
            Spacer()
            accessory
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}
#endif
