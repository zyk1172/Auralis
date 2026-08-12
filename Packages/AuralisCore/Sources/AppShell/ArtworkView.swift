import DesignSystem
import SwiftUI
import ThemeEngine
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

#if os(macOS)
public typealias PlatformImage = NSImage
#elseif os(iOS)
public typealias PlatformImage = UIImage
#endif

extension Image {
    init(platformImage: PlatformImage) {
        #if os(macOS)
        self.init(nsImage: platformImage)
        #else
        self.init(uiImage: platformImage)
        #endif
    }
}

/// 封面占位样式。
/// - `.auralis`：现有渐变 + 标题占位（iOS 默认，保持现有行为）。
/// - `.macMusic`：浅灰方块 + 中央灰色 music note（Mac Apple Music 视觉）。
enum ArtworkPlaceholderStyle: Sendable {
    case auralis
    case macMusic

    /// 平台默认：Mac 使用 macMusic，iOS 保持 auralis（不改 iOS 截图）。
    static var platformDefault: ArtworkPlaceholderStyle {
        #if os(macOS)
        return .macMusic
        #else
        return .auralis
        #endif
    }
}

/// 服务器封面视图：已加载时显示真实封面，加载中或服务器没有封面时
/// 回退到占位组件（Mac 为灰色 music note）。视图只订阅独立封面管线，不观察全局 AppModel。
struct ArtworkView: View {
    @Environment(ArtworkStore.self) private var artworkStore
    @State private var image: PlatformImage?
    let title: String
    let artworkKey: String?
    let colors: ThemeColors
    let size: CGFloat
    var cornerRadius: CGFloat = AuralisRadius.artwork
    var placeholderStyle: ArtworkPlaceholderStyle = .platformDefault

    /// 按 2x 屏幕密度请求，兼顾清晰度与流量。
    private var pixelSize: Int { max(64, Int(size * 2)) }

    private var requestIdentifier: String? {
        artworkStore.requestIdentifier(remoteKey: artworkKey, targetPixelSize: pixelSize)
    }

    var body: some View {
        ZStack {
            placeholder
            if let image {
                Image(platformImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    .transition(.opacity)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel("\(title) 封面")
        .task(id: requestIdentifier) {
            image = artworkStore.image(remoteKey: artworkKey, targetPixelSize: pixelSize)
            if image == nil {
                image = await artworkStore.load(
                    remoteKey: artworkKey,
                    targetPixelSize: pixelSize
                )
            }
        }
    }

    @ViewBuilder
    private var placeholder: some View {
        switch placeholderStyle {
        case .auralis:
            AuralisArtwork(title: title, colors: colors, size: size, cornerRadius: cornerRadius)
        case .macMusic:
            MacArtworkPlaceholder(size: size, cornerRadius: cornerRadius)
        }
    }
}

/// Apple Music 式占位：浅灰方块 + 中央灰色 music note。无边框、无主题色。
/// iOS 默认不启用（platformDefault 返回 .auralis），仅显式指定 .macMusic 时使用。
private struct MacArtworkPlaceholder: View {
    let size: CGFloat
    let cornerRadius: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.secondary.opacity(colorScheme == .dark ? 0.12 : 0.08))
            Image(systemName: "music.note")
                .font(.system(size: size * 0.25, weight: .regular))
                .foregroundStyle(.tertiary)
        }
        .frame(width: size, height: size)
    }
}
