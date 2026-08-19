import DesignSystem
import Domain
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
    /// 可选注入：环境缺失时降级为占位图，避免强解包崩溃。
    @Environment(\.artworkStore) private var artworkStore: ArtworkStore?
    @State private var image: PlatformImage?
    let title: String
    let artworkKey: String?
    let colors: ThemeColors
    let size: CGFloat
    /// 封面所属服务器（R01）：播放器封面显式传 `currentTrack.serverID`，保证
    /// 播放 A、浏览 B 时 A 的封面仍从 A 回源。nil = 当前浏览服务器（浏览型封面）。
    var serverID: ServerID?
    var cornerRadius: CGFloat = AuralisRadius.artwork
    var placeholderStyle: ArtworkPlaceholderStyle = .platformDefault

    @Environment(\.displayScale) private var displayScale

    /// 请求像素尺寸：先按实际 displayScale 折算，再量化到固定档位，
    /// 让窗口/列表轻微 resize 时命中同一封面缓存（Mac 尤其重要）。
    private var requestedPixelSize: Int {
        max(64, Int((size * displayScale).rounded()))
    }

    /// 量化到固定档位，避免同一封面因尺寸微调产生一堆 cache miss。
    /// 向上取整：Retina 下宁愿稍高一点，也不拿低分辨率封面放大。
    private static func normalizedPixelSize(_ requested: Int) -> Int {
        let buckets = [64, 96, 160, 256, 384, 512, 768, 1024, 1536, 2048]
        return buckets.first { $0 >= requested } ?? min(requested, 4096)
    }

    private var pixelSize: Int {
        Self.normalizedPixelSize(requestedPixelSize)
    }

    private var requestIdentifier: String? {
        artworkStore?.requestIdentifier(remoteKey: artworkKey, targetPixelSize: pixelSize, serverID: serverID)
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
            guard let artworkStore else {
                // Release 不崩溃（占位图兜底），但 Debug 必须暴露依赖注入错误：
                // 覆盖环境缺失前可能残留的旧封面，避免「显示错封面」静默发生。
                image = nil
                #if DEBUG
                assertionFailure("ArtworkView rendered without ArtworkStore environment")
                #endif
                return
            }
            image = artworkStore.image(remoteKey: artworkKey, targetPixelSize: pixelSize, serverID: serverID)
            if image == nil {
                image = await artworkStore.load(
                    remoteKey: artworkKey,
                    targetPixelSize: pixelSize,
                    serverID: serverID
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
