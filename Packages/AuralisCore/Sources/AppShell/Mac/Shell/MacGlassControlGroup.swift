#if os(macOS)
import SwiftUI

/// Liquid Glass 控制胶囊（CONTROL LAYER 专用，禁止用于内容层）。
/// macOS 15 安全实现：ultraThinMaterial + 描边 + 轻阴影；
/// 若未来 SDK 提供真正的 .glassEffect 视图修饰符，可在此处统一替换并 availability gate。
struct GlassControlGroup<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .background(.ultraThinMaterial, in: Capsule())
            .overlay {
                Capsule()
                    .stroke(Color.white.opacity(0.10), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
            .accessibilityElement(children: .contain)
    }
}
#endif
