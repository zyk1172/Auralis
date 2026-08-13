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
                    .overlay {
                        Capsule().stroke(
                            LinearGradient(
                                colors: [.white.opacity(0.72), .white.opacity(0.18), .white.opacity(0.46)],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 1
                        )
                    }
            } else {
                content
                    .background {
                        Capsule()
                            .fill(.ultraThinMaterial)
                            .overlay {
                                Capsule().fill(
                                    LinearGradient(
                                        colors: [.white.opacity(0.34), .white.opacity(0.12), .black.opacity(0.14)],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                            }
                    }
                    .overlay {
                        Capsule().stroke(
                            LinearGradient(
                                colors: [.white.opacity(0.78), .white.opacity(0.26), .white.opacity(0.52)],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 1
                        )
                    }
                    .shadow(color: .white.opacity(0.22), radius: 1, y: -1)
                    .shadow(color: .black.opacity(0.30), radius: 16, y: 8)
            }
        }
    }
}
#endif
