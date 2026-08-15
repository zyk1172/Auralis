import Application
import Foundation
import ImagePipeline
import Observation
import SwiftUI
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

/// 封面缓存与加载入口。
///
/// SwiftUI 封面视图只依赖这个对象，不再观察 `AuralisAppModel`。每个视图把加载结果
/// 放进自己的 `@State`，因此一张封面到达不会让所有可见封面一起重算。
@MainActor
@Observable
final class ArtworkStore {
    struct MemoryConfiguration: Sendable {
        var thumbnailCostLimit: Int = 64 * 1024 * 1024
        var thumbnailCountLimit: Int = 480
        var fullSizeCostLimit: Int = 48 * 1024 * 1024
        var fullSizeCountLimit: Int = 24
        var fullSizeThreshold: Int = 512
        var unavailableCountLimit: Int = 2_048

        static let `default` = MemoryConfiguration()
    }

    /// 渐进式预缓存使用的磁盘回退尺寸。
    static let fallbackPixelSize = 256

    typealias LoadObserver = @MainActor @Sendable (_ remoteKey: String, _ encodedData: Data) -> Void

    /// 仅服务器真正切换时变化；ArtworkView 将其纳入 task id，使可见单元自动重新取图。
    private(set) var namespace: String

    @ObservationIgnored private let thumbnails = NSCache<NSString, PlatformImage>()
    @ObservationIgnored private let fullSizeImages = NSCache<NSString, PlatformImage>()
    @ObservationIgnored private let unavailable = NSCache<NSString, NSNumber>()
    @ObservationIgnored private let pipeline: ArtworkPipeline
    @ObservationIgnored private let configuration: MemoryConfiguration
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var memoryPressureMonitor: ArtworkMemoryPressureMonitor?
    @ObservationIgnored var onArtworkLoaded: LoadObserver?

    init(
        connector: any ServerConnecting,
        diskCache: ArtworkDiskCache,
        initialServerID: String? = nil,
        configuration: MemoryConfiguration = .default,
        decoder: ArtworkImageDecoder = ArtworkImageDecoder()
    ) {
        self.namespace = Self.normalizedNamespace(initialServerID)
        self.configuration = configuration
        self.pipeline = ArtworkPipeline(
            connector: connector,
            diskCache: diskCache,
            decoder: decoder
        )

        thumbnails.name = "Auralis.Artwork.Thumbnails"
        thumbnails.totalCostLimit = max(1, configuration.thumbnailCostLimit)
        thumbnails.countLimit = max(1, configuration.thumbnailCountLimit)
        fullSizeImages.name = "Auralis.Artwork.FullSize"
        fullSizeImages.totalCostLimit = max(1, configuration.fullSizeCostLimit)
        fullSizeImages.countLimit = max(1, configuration.fullSizeCountLimit)
        unavailable.name = "Auralis.Artwork.Unavailable"
        unavailable.countLimit = max(1, configuration.unavailableCountLimit)

        installMemoryPressureHandling()
    }

    func cacheKey(_ remoteKey: String, targetPixelSize: Int) -> String {
        Self.cacheKey(
            namespace: namespace,
            remoteKey: remoteKey,
            targetPixelSize: targetPixelSize
        )
    }

    func requestIdentifier(remoteKey: String?, targetPixelSize: Int) -> String? {
        guard let remoteKey, !remoteKey.isEmpty else { return nil }
        return cacheKey(remoteKey, targetPixelSize: targetPixelSize)
    }

    func image(forKey key: String) -> PlatformImage? {
        let objectKey = key as NSString
        return thumbnails.object(forKey: objectKey) ?? fullSizeImages.object(forKey: objectKey)
    }

    func image(remoteKey: String?, targetPixelSize: Int) -> PlatformImage? {
        guard let remoteKey, !remoteKey.isEmpty else { return nil }
        return image(forKey: cacheKey(remoteKey, targetPixelSize: targetPixelSize))
    }

    func isUnavailable(_ key: String) -> Bool {
        unavailable.object(forKey: key as NSString) != nil
    }

    /// 返回内存命中，或异步经过磁盘/网络与 ImageIO 下采样后的最终图片。
    func load(remoteKey: String?, targetPixelSize: Int) async -> PlatformImage? {
        guard let remoteKey, !remoteKey.isEmpty else { return nil }
        let target = min(max(1, targetPixelSize), 4_096)
        let requestNamespace = namespace
        let requestGeneration = generation
        let key = Self.cacheKey(
            namespace: requestNamespace,
            remoteKey: remoteKey,
            targetPixelSize: target
        )
        if let image = image(forKey: key) { return image }
        guard !isUnavailable(key) else { return nil }

        let fallbackKey = Self.cacheKey(
            namespace: requestNamespace,
            remoteKey: remoteKey,
            targetPixelSize: Self.fallbackPixelSize
        )
        guard let payload = await pipeline.load(
            remoteKey: remoteKey,
            cacheKey: key,
            fallbackCacheKey: fallbackKey,
            targetPixelSize: target
        ) else {
            guard requestNamespace == namespace, requestGeneration == generation else { return nil }
            markUnavailable(key)
            return nil
        }

        // 切库期间完成的旧请求不得污染新服务器内存缓存。
        guard requestNamespace == namespace,
              requestGeneration == generation,
              !Task.isCancelled
        else { return nil }
        let image = Self.platformImage(from: payload.decoded)
        setImage(image, forKey: key, targetPixelSize: target, cost: payload.decoded.memoryCost)
        onArtworkLoaded?(remoteKey, payload.encodedData)
        return image
    }

    /// 兼容同步调用者；新代码应优先使用 `load(remoteKey:targetPixelSize:)`。
    func setImage(_ image: PlatformImage, forKey key: String) {
        let target = Self.pixelSize(fromCacheKey: key) ?? 1
        setImage(image, forKey: key, targetPixelSize: target, cost: Self.memoryCost(of: image))
    }

    func markUnavailable(_ key: String) {
        unavailable.setObject(NSNumber(value: true), forKey: key as NSString)
    }

    /// 更新服务器命名空间。磁盘缓存按服务器隔离，切库只清理进程内图片与旧请求。
    func setServerID(_ serverID: String?) {
        let next = Self.normalizedNamespace(serverID)
        guard namespace != next else { return }
        namespace = next
        reset()
    }

    /// 清空全部内存封面与失败记录；磁盘缓存由 ArtworkDiskCache 单独管理。
    func reset() {
        generation &+= 1
        thumbnails.removeAllObjects()
        fullSizeImages.removeAllObjects()
        unavailable.removeAllObjects()
        Task { await pipeline.cancelAll() }
    }

    /// 同库增量刷新后允许此前失败的封面重试，保留已解码图片。
    func clearUnavailable() {
        unavailable.removeAllObjects()
    }

    /// 系统内存告警时主动释放全部解码位图；之后可从磁盘缓存廉价恢复。
    func handleMemoryPressure() {
        thumbnails.removeAllObjects()
        fullSizeImages.removeAllObjects()
    }

    // MARK: - Private

    private func setImage(
        _ image: PlatformImage,
        forKey key: String,
        targetPixelSize: Int,
        cost: Int
    ) {
        let cache = targetPixelSize >= configuration.fullSizeThreshold ? fullSizeImages : thumbnails
        cache.setObject(image, forKey: key as NSString, cost: max(1, cost))
        unavailable.removeObject(forKey: key as NSString)
    }

    private func installMemoryPressureHandling() {
        memoryPressureMonitor = ArtworkMemoryPressureMonitor { [weak self] in
            self?.handleMemoryPressure()
        }
    }

    private static func normalizedNamespace(_ serverID: String?) -> String {
        guard let serverID = serverID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !serverID.isEmpty
        else { return "local" }
        return serverID
    }

    private static func cacheKey(
        namespace: String,
        remoteKey: String,
        targetPixelSize: Int
    ) -> String {
        "\(namespace)|\(remoteKey)@\(min(max(1, targetPixelSize), 4_096))"
    }

    private static func pixelSize(fromCacheKey key: String) -> Int? {
        guard let separator = key.lastIndex(of: "@") else { return nil }
        return Int(key[key.index(after: separator)...])
    }

    private static func platformImage(from decoded: DecodedArtwork) -> PlatformImage {
        #if os(macOS)
        return NSImage(
            cgImage: decoded.image,
            size: NSSize(width: decoded.pixelWidth, height: decoded.pixelHeight)
        )
        #else
        return UIImage(cgImage: decoded.image, scale: 1, orientation: .up)
        #endif
    }

    private static func memoryCost(of image: PlatformImage) -> Int {
        #if os(macOS)
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return 1
        }
        #else
        guard let cgImage = image.cgImage else { return 1 }
        #endif
        let (pixels, pixelOverflow) = cgImage.width.multipliedReportingOverflow(by: cgImage.height)
        let (bytes, byteOverflow) = pixels.multipliedReportingOverflow(by: 4)
        return pixelOverflow || byteOverflow ? Int.max : bytes
    }
}

/// 把 Foundation / Dispatch 的非 Sendable 观察者句柄封装在自己的生命周期里。
/// ArtworkStore 的 nonisolated deinit 无需再触碰 NSObjectProtocol。
private final class ArtworkMemoryPressureMonitor: @unchecked Sendable {
    #if os(iOS)
    private var observer: NSObjectProtocol?
    #elseif os(macOS)
    private var source: DispatchSourceMemoryPressure?
    #endif

    init(handler: @escaping @MainActor @Sendable () -> Void) {
        #if os(iOS)
        observer = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { handler() }
        }
        #elseif os(macOS)
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .main
        )
        source.setEventHandler {
            MainActor.assumeIsolated { handler() }
        }
        source.resume()
        self.source = source
        #endif
    }

    deinit {
        #if os(iOS)
        if let observer { NotificationCenter.default.removeObserver(observer) }
        #elseif os(macOS)
        source?.cancel()
        #endif
    }
}

// MARK: - 可选环境注入

/// 可选封面存储注入：以 key-path 形式注入（`\\.artworkStore`）。
/// 封面视图用 `@Environment(\\ .artworkStore)` 读取；注入缺失时优雅降级为占位图，
/// 而不是像 `@Environment(ArtworkStore.self)` 那样强解包崩溃（
/// “Expanded 内 ArtworkView 强解包崩溃”的根治：环境缺失不再致命）。
private struct ArtworkStoreEnvironmentKey: EnvironmentKey {
    static let defaultValue: ArtworkStore? = nil
}

extension EnvironmentValues {
    var artworkStore: ArtworkStore? {
        get { self[ArtworkStoreEnvironmentKey.self] }
        set { self[ArtworkStoreEnvironmentKey.self] = newValue }
    }
}
