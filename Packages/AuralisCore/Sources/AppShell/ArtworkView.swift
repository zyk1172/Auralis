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

/// 服务器封面视图：已加载时显示真实封面，加载中或服务器没有封面时
/// 回退到渐变占位组件。视图只订阅独立封面管线，不观察全局 AppModel。
struct ArtworkView: View {
    @Environment(ArtworkStore.self) private var artworkStore
    @State private var image: PlatformImage?
    let title: String
    let artworkKey: String?
    let colors: ThemeColors
    let size: CGFloat
    var cornerRadius: CGFloat = AuralisRadius.artwork

    /// 按 2x 屏幕密度请求，兼顾清晰度与流量。
    private var pixelSize: Int { max(64, Int(size * 2)) }

    private var requestIdentifier: String? {
        artworkStore.requestIdentifier(remoteKey: artworkKey, targetPixelSize: pixelSize)
    }

    var body: some View {
        ZStack {
            AuralisArtwork(title: title, colors: colors, size: size, cornerRadius: cornerRadius)
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
}
