import DesignSystem
import SwiftUI
import ThemeEngine

// MARK: - 封面调色板（辅助光取色）

/// 辅助光配色：主色 + 辅助色。只用于极轻的补光椭圆和无封面回退，不再是主光源。
struct ArtworkPalette: Equatable {
    let primary: Color
    let secondary: Color
}

/// 从封面小图采样主色/辅助色：24×24 下采样后取平均色与高饱和平均色，
/// 按封面 key 缓存（最多 200 条，防止曲库大时无限增长）。
/// 提取失败（无封面/未加载）时回退到页面背景渐变的主色（主题强调色）。
final class ArtworkPaletteStore: @unchecked Sendable {
    static let shared = ArtworkPaletteStore()
    private let lock = NSLock()
    private var cache: [String: ArtworkPalette] = [:]
    private static let maxEntries = 200

    func palette(
        for key: String?,
        image: PlatformImage?,
        fallbackPrimary: Color,
        fallbackSecondary: Color
    ) -> ArtworkPalette {
        guard let key, let image else {
            return ArtworkPalette(primary: fallbackPrimary, secondary: fallbackSecondary)
        }
        lock.lock()
        if let cached = cache[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let sampled = Self.sample(image)
        let palette: ArtworkPalette
        if let primary = sampled.primary {
            palette = ArtworkPalette(primary: primary, secondary: sampled.secondary ?? primary)
        } else {
            palette = ArtworkPalette(primary: fallbackPrimary, secondary: fallbackSecondary)
        }
        lock.lock()
        cache[key] = palette
        if cache.count > Self.maxEntries, let oldest = cache.keys.first {
            cache.removeValue(forKey: oldest)
        }
        lock.unlock()
        return palette
    }

    /// 24×24 采样：平均色 = 主色；高饱和像素平均 = 辅助色（更接近封面“有色彩”的部分）。
    private static func sample(_ image: PlatformImage) -> (primary: Color?, secondary: Color?) {
        #if os(iOS)
        guard let cg = image.cgImage else { return (nil, nil) }
        #else
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return (nil, nil) }
        #endif
        let side = 24
        var data = [UInt8](repeating: 0, count: side * side * 4)
        guard let context = CGContext(
            data: &data, width: side, height: side,
            bitsPerComponent: 8, bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return (nil, nil) }
        context.interpolationQuality = .medium
        context.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))

        var rSum = 0.0, gSum = 0.0, bSum = 0.0
        var saturated: [(Double, Double, Double)] = []
        var count = 0
        for i in stride(from: 0, to: data.count, by: 4) {
            let r = Double(data[i]) / 255.0
            let g = Double(data[i + 1]) / 255.0
            let b = Double(data[i + 2]) / 255.0
            rSum += r; gSum += g; bSum += b
            count += 1
            if max(r, g, b) - min(r, g, b) > 0.18 { saturated.append((r, g, b)) }
        }
        guard count > 0 else { return (nil, nil) }
        let primary = Self.softColor(rSum / Double(count), gSum / Double(count), bSum / Double(count))
        if !saturated.isEmpty {
            let sr = saturated.map(\.0).reduce(0, +) / Double(saturated.count)
            let sg = saturated.map(\.1).reduce(0, +) / Double(saturated.count)
            let sb = saturated.map(\.2).reduce(0, +) / Double(saturated.count)
            return (primary, Self.softColor(sr, sg, sb))
        }
        return (primary, primary)
    }

    /// 轻微压饱和、按亮度提亮，避免霓虹感，同时保证在深色背景上可感知。
    private static func softColor(_ r: Double, _ g: Double, _ b: Double) -> Color {
        let luminance = 0.299 * r + 0.587 * g + 0.114 * b
        let lift = max(0, 0.30 - luminance) * 0.35
        let mix: Double = 0.18  // 与中性亮色混合，让光效更柔和
        return Color(
            red: min(1, r * (1 - mix) + mix + lift),
            green: min(1, g * (1 - mix) + mix + lift),
            blue: min(1, b * (1 - mix) + mix + lift)
        )
    }
}

// MARK: - 播放态封面环境光

/// “正在播放”封面的环境光。主光源是真实封面本身的低分辨率副本：
/// 放大 → 轻微提饱和 → 高斯模糊 → 低透明度，让光线从封面向外扩散，
/// 而不是在封面后面再画一个大号 RoundedRectangle 色板。
///
/// 设计约束：
/// - 只复用 ArtworkStore 已缓存的低分辨率封面，不重新加载高清封面；
/// - Glow 画布明显大于封面本体（约 1.5×），给模糊扩散留出外围空间；
/// - 播放时缓慢呼吸（3.6s 周期），暂停保持弱静态光，Reduce Motion 完全静止；
/// - 不进行每帧图片分析，调色板只在封面变化时计算并缓存。
struct NowPlayingArtworkGlowView: View {
    @Environment(ArtworkStore.self) private var artworkStore
    @State private var artworkImage: PlatformImage?
    let isPlaying: Bool
    let artworkKey: String?
    let colors: ThemeColors
    let size: CGFloat
    /// 页面允许的最大 Glow 画布。默认无限制（1.5× 封面），紧凑布局由调用方传入
    /// 实际可用高度，避免光效把页面边缘裁成方框，同时不改变封面布局足迹。
    var maxCanvasSize: CGFloat = .greatestFiniteMagnitude
    var cornerRadius: CGFloat = AuralisRadius.artwork
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Glow 画布：明显大于封面本体，避免模糊被页面边缘直接裁成方框。
    private var canvasSize: CGFloat { min(size * 1.5, max(0, maxCanvasSize)) }
    /// 主光源副本放大比例（相对封面）。
    private var lightScale: CGFloat { 1.28 }
    /// 高斯模糊半径随封面尺寸缩放；使用 SwiftUI 系统 GPU 路径。
    private var blurRadius: CGFloat { max(12, size * 0.10) }

    private var pixelSize: Int { max(64, Int(size * 2)) }

    private var requestIdentifier: String? {
        artworkStore.requestIdentifier(remoteKey: artworkKey, targetPixelSize: pixelSize)
    }

    private var animates: Bool { isPlaying && !reduceMotion }

    var body: some View {
        // 调色板只在封面变化/加载完成时计算（ArtworkPaletteStore 已按 key 缓存），
        // 用于无封面回退与极轻的补光椭圆；主光源始终是真实封面本身。
        let palette = ArtworkPaletteStore.shared.palette(
            for: artworkKey,
            image: artworkImage,
            fallbackPrimary: colors.accent.color,
            fallbackSecondary: colors.accentSecondary.color
        )
        // 布局足迹始终等于封面尺寸（size × size），Glow 画布以 overlay 向外扩散，
        // 不会改变播放页布局，也不会因光效把封面本体撑大。
        Color.clear
            .frame(width: size, height: size)
            .overlay {
                ArtworkAmbientLight(
                    image: artworkImage,
                    palettePrimary: palette.primary,
                    paletteSecondary: palette.secondary,
                    canvasSize: canvasSize,
                    lightScale: lightScale,
                    blurRadius: blurRadius,
                    cornerRadius: cornerRadius,
                    animates: animates
                )
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .task(id: requestIdentifier) {
            artworkImage = artworkStore.image(remoteKey: artworkKey, targetPixelSize: pixelSize)
            if artworkImage == nil {
                artworkImage = await artworkStore.load(
                    remoteKey: artworkKey,
                    targetPixelSize: pixelSize
                )
            }
        }
    }
}

/// 单层环境光：真实封面副本放大 + 提饱和 + 高斯模糊，径向淡出到透明。
/// 没有封面时退化为极轻的径向补光；补光椭圆只负责环境亮度，不形成矩形底板。
struct ArtworkAmbientLight: View {
    let image: PlatformImage?
    let palettePrimary: Color
    let paletteSecondary: Color
    let canvasSize: CGFloat
    let lightScale: CGFloat
    let blurRadius: CGFloat
    let cornerRadius: CGFloat
    let animates: Bool
    @State private var breathe = false

    /// 呼吸范围：scale 0.99 ↔ 1.04，opacity 轻微起伏（C5 要求 3~5 秒周期、低速）。
    private var lightFrame: CGFloat { canvasSize * lightScale }
    private var glowOpacity: Double { animates ? (breathe ? 0.44 : 0.30) : 0.30 }
    private var glowScale: CGFloat { animates ? (breathe ? 1.04 : 0.99) : 1.0 }

    var body: some View {
        ZStack {
            if let image {
                // 先按封面形状 clip 源图，再整体模糊；最后用径向 mask 淡出，
                // 不再把光晕裁回矩形。
                Image(platformImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: lightFrame, height: lightFrame)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius * lightScale, style: .continuous))
                    .saturation(1.15)
                    .blur(radius: blurRadius)
                    .scaleEffect(glowScale)
                    .opacity(glowOpacity)
                    .mask(
                        RadialGradient(
                            colors: [.white, .white.opacity(0.65), .clear],
                            center: .center,
                            startRadius: 0,
                            endRadius: canvasSize * 0.62
                        )
                    )
            } else {
                // 无封面：极轻径向补光，仅提供环境亮度。
                RadialGradient(
                    colors: [palettePrimary.opacity(0.16), paletteSecondary.opacity(0.06), .clear],
                    center: .center,
                    startRadius: canvasSize * 0.10,
                    endRadius: canvasSize * 0.50
                )
                .scaleEffect(glowScale)
                .opacity(glowOpacity)
            }

            // 补光椭圆：极低透明度，给环境一点方向感；位于真实封面光晕之后。
            Ellipse()
                .fill(
                    RadialGradient(
                        colors: [paletteSecondary.opacity(0.12), paletteSecondary.opacity(0.04), .clear],
                        center: .center,
                        startRadius: 0,
                        endRadius: canvasSize * 0.42
                    )
                )
                .frame(width: canvasSize * 0.9, height: canvasSize * 0.55)
                .offset(y: -canvasSize * 0.04)
                .blur(radius: blurRadius * 0.8)
                .opacity(glowOpacity * 0.35)
        }
        .onAppear { update(animates: animates) }
        .onChange(of: animates) { _, newValue in update(animates: newValue) }
    }

    private func update(animates: Bool) {
        if animates {
            withAnimation(.easeInOut(duration: 3.6).repeatForever(autoreverses: true)) {
                breathe = true
            }
        } else {
            withAnimation(.easeOut(duration: 0.8)) {
                breathe = false
            }
        }
    }
}
