import DesignSystem
import SwiftUI
import ThemeEngine

// MARK: - 封面调色板（光效取色）

/// 光效配色：主色 + 辅助色。
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

// MARK: - 播放态动态光效（封面后方，3 层）

/// “正在播放”封面的动态光效：静态柔光底 + 呼吸式主光晕 + 间歇波纹扩散。
/// 通过独立封面管线取色；动画由 isPlaying 驱动，切歌时颜色随封面平滑过渡。
struct NowPlayingArtworkGlowView: View {
    @Environment(ArtworkStore.self) private var artworkStore
    @State private var artworkImage: PlatformImage?
    let isPlaying: Bool
    let artworkKey: String?
    let title: String
    let colors: ThemeColors
    let size: CGFloat
    var cornerRadius: CGFloat = AuralisRadius.artwork
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var pixelSize: Int { max(64, Int(size * 2)) }

    private var requestIdentifier: String? {
        artworkStore.requestIdentifier(remoteKey: artworkKey, targetPixelSize: pixelSize)
    }

    var body: some View {
        // 与封面同尺寸的“不可见”占位，光效从中心向外扩散，绝不遮挡封面/文字。
        let palette = ArtworkPaletteStore.shared.palette(
            for: artworkKey,
            image: artworkImage,
            fallbackPrimary: colors.accent.color,
            fallbackSecondary: colors.accentSecondary.color
        )
        ZStack {
            ArtworkStaticGlowLayer(color: palette.primary, size: size, cornerRadius: cornerRadius)
            ArtworkBreathingGlowLayer(
                isPlaying: isPlaying && !reduceMotion,
                color: palette.primary,
                size: size,
                cornerRadius: cornerRadius
            )
            ArtworkRippleLayer(
                isPlaying: isPlaying && !reduceMotion,
                color: palette.secondary,
                size: size,
                cornerRadius: cornerRadius
            )
        }
        .frame(width: size, height: size)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        // 切歌/封面加载完成时颜色平滑过渡，不跳色。
        .animation(.easeInOut(duration: 0.8), value: palette.primary)
        .animation(.easeInOut(duration: 0.8), value: palette.secondary)
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

/// 第 1 层：静态柔光底层。始终存在、很轻，提供“氛围基座”。
struct ArtworkStaticGlowLayer: View {
    let color: Color
    let size: CGFloat
    let cornerRadius: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(
                RadialGradient(
                    colors: [color.opacity(0.30), color.opacity(0.08), .clear],
                    center: .center,
                    startRadius: size * 0.28,
                    endRadius: size * 0.72
                )
            )
            .frame(width: size * 1.9, height: size * 1.9)
            .blur(radius: 30)
            .opacity(0.55)
    }
}

/// 第 2 层：呼吸式主光晕。播放时缓慢明暗起伏 + 半径微变；暂停时停在较弱状态。
struct ArtworkBreathingGlowLayer: View {
    let isPlaying: Bool
    let color: Color
    let size: CGFloat
    let cornerRadius: CGFloat
    @State private var breathe = false

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(
                RadialGradient(
                    colors: [color.opacity(isPlaying ? 0.52 : 0.16), color.opacity(0.10), .clear],
                    center: .center,
                    startRadius: size * 0.30,
                    endRadius: size * 0.78
                )
            )
            .frame(width: size * 1.7, height: size * 1.7)
            .scaleEffect(isPlaying ? (breathe ? 1.07 : 0.98) : 1.0)
            .opacity(isPlaying ? (breathe ? 0.85 : 0.45) : 0.22)
            .blur(radius: 26)
            .onAppear { update(playing: isPlaying) }
            .onChange(of: isPlaying) { _, playing in update(playing: playing) }
    }

    private func update(playing: Bool) {
        if playing {
            withAnimation(.easeInOut(duration: 3.2).repeatForever(autoreverses: true)) {
                breathe = true
            }
        } else {
            withAnimation(.easeOut(duration: 0.9)) {
                breathe = false
            }
        }
    }
}

/// 第 3 层：间歇波纹扩散层。播放时每隔约 2.6s 扩散 1～2 圈柔光波纹，透明度递减消失。
struct ArtworkRippleLayer: View {
    let isPlaying: Bool
    let color: Color
    let size: CGFloat
    let cornerRadius: CGFloat
    @State private var ripples: [Ripple] = []

    struct Ripple: Identifiable {
        let id = UUID()
        var progress: CGFloat = 0
    }

    var body: some View {
        ZStack {
            ForEach(ripples) { ripple in
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(
                        RadialGradient(
                            colors: [color.opacity(0.30), color.opacity(0.08), .clear],
                            center: .center,
                            startRadius: size * 0.20,
                            endRadius: size * 0.50
                        )
                    )
                    .frame(width: size * 1.25, height: size * 1.25)
                    .scaleEffect(1 + ripple.progress * 0.22)
                    .opacity(0.5 * (1 - ripple.progress))
                    .blur(radius: 8)
            }
        }
        .task(id: isPlaying) {
            guard isPlaying else { return }
            // 播放中循环触发；暂停/离开页面时 .task(id:) 自动取消，不残留后台资源。
            while !Task.isCancelled {
                spawnRipple()
                try? await Task.sleep(nanoseconds: 2_600_000_000)
            }
        }
        .onChange(of: isPlaying) { _, playing in
            if !playing {
                withAnimation(.easeOut(duration: 0.5)) {
                    ripples.removeAll()
                }
            }
        }
    }

    private func spawnRipple() {
        guard ripples.count < 2 else { return }
        let ripple = Ripple()
        ripples.append(ripple)
        withAnimation(.easeOut(duration: 2.2)) {
            guard let index = ripples.firstIndex(where: { $0.id == ripple.id }) else { return }
            ripples[index].progress = 1
        }
        // 动画结束后移除，避免数组无限增长。
        Task {
            try? await Task.sleep(nanoseconds: 2_400_000_000)
            await MainActor.run {
                ripples.removeAll { $0.id == ripple.id }
            }
        }
    }
}
