#if os(macOS)
import SwiftUI

/// Liquid Glass 控制胶囊（CONTROL LAYER 专用）。
/// macOS 26+ 使用真实 `glassEffect(.regular.interactive(), in:)`（已核对 Xcode 27 SDK）；
/// macOS 15 fallback 为 ultraThinMaterial 胶囊 + 描边 + 轻阴影。
/// 只对真正内容命中（content 本身即胶囊范围），禁止用于内容层。
struct MacGlassCapsule<Content: View>: View {
    private let content: Content
    private let colorScheme: ColorScheme

    init(colorScheme: ColorScheme = .dark, @ViewBuilder content: () -> Content) {
        self.colorScheme = colorScheme
        self.content = content()
    }

    var body: some View {
        let isLight = colorScheme == .light
        let highlight = isLight ? Color.white.opacity(0.78) : Color.white.opacity(0.72)
        let midtone = isLight ? Color.black.opacity(0.14) : Color.white.opacity(0.18)
        let edge = isLight ? Color.black.opacity(0.28) : Color.white.opacity(0.46)
        Group {
            if #available(macOS 26.0, *) {
                content
                    .glassEffect(.regular.interactive(), in: Capsule())
                    .overlay {
                        Capsule().stroke(
                            LinearGradient(
                                colors: [highlight, midtone, edge],
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
                                        colors: isLight
                                            ? [.white.opacity(0.62), .white.opacity(0.34), .black.opacity(0.08)]
                                            : [.white.opacity(0.34), .white.opacity(0.12), .black.opacity(0.14)],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                            }
                    }
                    .overlay {
                        Capsule().stroke(
                            LinearGradient(
                                colors: [highlight, midtone, edge],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 1
                        )
                    }
                    .shadow(color: isLight ? .white.opacity(0.42) : .white.opacity(0.22), radius: 1, y: -1)
                    .shadow(color: .black.opacity(isLight ? 0.18 : 0.30), radius: 16, y: 8)
            }
        }
    }
}
#endif
