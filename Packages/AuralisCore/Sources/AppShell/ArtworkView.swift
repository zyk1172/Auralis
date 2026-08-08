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
/// 回退到渐变占位组件。按需加载由 AuralisAppModel 统一调度与缓存。
struct ArtworkView: View {
    /// 只观察独立封面存储：封面到达只刷新本卡片，不触发首页整体重建。
    @Environment(ArtworkStore.self) private var artworkStore
    @EnvironmentObject var model: AuralisAppModel
    let title: String
    let artworkKey: String?
    let colors: ThemeColors
    let size: CGFloat
    var cornerRadius: CGFloat = AuralisRadius.artwork

    /// 按 2x 屏幕密度请求，兼顾清晰度与流量。
    private var pixelSize: Int { max(64, Int(size * 2)) }

    var body: some View {
        ZStack {
            AuralisArtwork(title: title, colors: colors, size: size, cornerRadius: cornerRadius)
            if let artworkKey,
               let image = artworkStore.image(forKey: model.artworkCacheKey(artworkKey, pixelSize)) {
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
        .task(id: artworkKey) {
            model.loadArtwork(key: artworkKey, targetPixelSize: pixelSize)
        }
    }
}
