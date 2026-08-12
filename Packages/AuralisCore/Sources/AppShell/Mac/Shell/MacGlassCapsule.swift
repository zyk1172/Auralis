#if os(macOS)
import SwiftUI

/// Liquid Glass 控制胶囊（CONTROL LAYER 专用）。
/// macOS 26+ 使用真实 `glassEffect(.regular.interactive(), in:)`（已核对 Xcode 27 SDK）；
/// macOS 15 fallback 为 ultraThinMaterial 胶囊 + 描边 + 轻阴影。
/// 只对真正内容命中（content 本身即胶囊范围），禁止用于内容层。
struct MacGlassCapsule<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        Group {
            if #available(macOS 26.0, *) {
                content
                    .glassEffect(.regular.interactive(), in: Capsule())
            } else {
                content
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay {
                        Capsule().stroke(Color.white.opacity(0.10), lineWidth: 0.5)
                    }
                    .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
            }
        }
    }
}
#endif
