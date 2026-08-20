import Application
import Domain
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
    /// 当前浏览服务器 ID（封面网络回源兜底，R01）。nil = 本地/未连接。
    /// 注意：这只是「未显式指定 serverID 的请求」的兜底——播放器封面等跨服务器场景
    /// 必须显式传 track.serverID，绝不能依赖这个全局值（播放 A、浏览 B 时
    /// 仍要把 A 的 artworkKey 发往 A）。
    @ObservationIgnored private var currentServerID: ServerID?

    @ObservationIgnored private let thumbnails = NSCache<NSString, PlatformImage>()
    @ObservationIgnored private let fullSizeImages = NSCache<NSString, PlatformImage>()
    @ObservationIgnored private let unavailable = NSCache<NSString, NSNumber>()
    @ObservationIgnored private let encodedDataCache = NSCache<NSString, NSData>()
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
        // R01：currentServerID 与 namespace 同步初始化——无显式 serverID 的兜底请求
        // 从创建起就按正确服务器路由，不必等第一次 setServerID。
        self.currentServerID = initialServerID.map(ServerID.init(rawValue:))
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
        encodedDataCache.name = "Auralis.Artwork.EncodedData"
        encodedDataCache.totalCostLimit = max(1, configuration.thumbnailCostLimit)
        encodedDataCache.countLimit = max(1, configuration.thumbnailCountLimit * 2)

        installMemoryPressureHandling()
    }

    func cacheKey(_ remoteKey: String, targetPixelSize: Int) -> String {
        Self.cacheKey(
            namespace: Self.normalizedNamespace(currentServerID?.rawValue),
            remoteKey: remoteKey,
            targetPixelSize: targetPixelSize
        )
    }

    func requestIdentifier(remoteKey: String?, targetPixelSize: Int, serverID: ServerID? = nil) -> String? {
        guard let remoteKey, !remoteKey.isEmpty else { return nil }
        return cacheKey(remoteKey, targetPixelSize: targetPixelSize, serverID: serverID)
    }

    func image(forKey key: String) -> PlatformImage? {
        let objectKey = key as NSString
        return thumbnails.object(forKey: objectKey) ?? fullSizeImages.object(forKey: objectKey)
    }

    func image(remoteKey: String?, targetPixelSize: Int, serverID: ServerID? = nil) -> PlatformImage? {
        guard let remoteKey, !remoteKey.isEmpty else { return nil }
        return image(forKey: cacheKey(remoteKey, targetPixelSize: targetPixelSize, serverID: serverID))
    }

    func isUnavailable(_ key: String) -> Bool {
        unavailable.object(forKey: key as NSString) != nil
    }

    /// Now Playing 等需要原始 encodedData 的场景：直接复用管线返回的 JPEG/PNG 字节，
    /// 避免在 MainActor 上做 NSImage → TIFF → PNG 的同步重编码。
    func encodedData(remoteKey: String?, serverID: ServerID? = nil) -> Data? {
        guard let remoteKey, !remoteKey.isEmpty else { return nil }
        let key = Self.encodedCacheKey(namespace: effectiveServerID(serverID).rawValue, remoteKey: remoteKey)
        return encodedDataCache.object(forKey: key as NSString) as Data?
    }

    /// 返回内存命中，或异步经过磁盘/网络与 ImageIO 下采样后的最终图片。
    /// - Parameter serverID: 封面所属服务器的显式 ID（R01）。播放器封面必须传
    ///   `currentTrack.serverID`——正在播放 A、浏览 B 时，A 的封面仍要从 A 回源，
    ///   且缓存键落在 A 的命名空间，不污染 B。nil 时回退当前浏览服务器。
    /// - 竞态边界（R01 收尾）：显式 serverID 的请求（播放器封面）**不受浏览服务器
    ///   切换影响**——切 B 浏览既不取消 A 的在途请求，也不因 browse generation
    ///   变化丢弃 A 的结果；只有 serverID == nil 的浏览型请求在切服后被丢弃。
    func load(remoteKey: String?, targetPixelSize: Int, serverID: ServerID? = nil) async -> PlatformImage? {
        guard let remoteKey, !remoteKey.isEmpty else { return nil }
        let target = min(max(1, targetPixelSize), 4_096)
        let isExplicit = serverID != nil
        let requestServerID = effectiveServerID(serverID)
        let requestGeneration = generation
        let key = Self.cacheKey(
            namespace: requestServerID.rawValue,
            remoteKey: remoteKey,
            targetPixelSize: target
        )
        if let image = image(forKey: key) { return image }
        guard !isUnavailable(key) else { return nil }

        let fallbackKey = Self.cacheKey(
            namespace: requestServerID.rawValue,
            remoteKey: remoteKey,
            targetPixelSize: Self.fallbackPixelSize
        )
        guard let payload = await pipeline.load(
            serverID: requestServerID,
            remoteKey: remoteKey,
            cacheKey: key,
            fallbackCacheKey: fallbackKey,
            targetPixelSize: target
        ) else {
            // 只有浏览型（兜底）请求在切服后丢弃并停止写失败记录。
            guard !isExplicit else { return nil }
            guard requestServerID == effectiveServerID(nil),
                  requestGeneration == generation
            else { return nil }
            markUnavailable(key)
            return nil
        }

        // 请求完成时的「代际是否仍有效」校验：
        // - 显式 serverID（播放器封面）：只校验任务未取消——缓存键已 server-scoped，
        //   切浏览服务器不影响 A 的结果落键；
        // - 浏览型兜底：切服（currentServerID 或 browse generation 变化）后丢弃，
        //   避免旧浏览服务器的结果污染新浏览状态。
        if isExplicit {
            guard !Task.isCancelled else { return nil }
        } else {
            guard requestServerID == effectiveServerID(nil),
                  requestGeneration == generation,
                  !Task.isCancelled
            else { return nil }
        }
        let image = Self.platformImage(from: payload.decoded)
        setImage(image, forKey: key, targetPixelSize: target, cost: payload.decoded.memoryCost)
        let encodedKey = Self.encodedCacheKey(namespace: requestServerID.rawValue, remoteKey: remoteKey)
        encodedDataCache.setObject(payload.encodedData as NSData, forKey: encodedKey as NSString, cost: payload.encodedData.count)
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

    /// 更新服务器命名空间。磁盘缓存按服务器隔离。
    /// R01 收尾：切浏览服务器**只递增浏览代际**（让旧的浏览型在途请求结果被丢弃），
    /// 不再清空所有服务器的内存缓存、不再 cancelAll 在途请求——缓存键已 server-scoped，
    /// 显式 serverID 的播放器封面（如 A 的歌在播、切到 B 浏览）不得被 B 的浏览切换
    /// 取消或清掉内存结果。
    func setServerID(_ serverID: String?) {
        currentServerID = serverID.map(ServerID.init(rawValue:))
        let next = Self.normalizedNamespace(serverID)
        guard namespace != next else { return }
        namespace = next
        generation &+= 1
    }

    /// 清空全部内存封面与失败记录；磁盘缓存由 ArtworkDiskCache 单独管理。
    /// 仅用于内存压力 / 显式清理路径，不再由切浏览服务器触发。
    func reset() {
        generation &+= 1
        thumbnails.removeAllObjects()
        fullSizeImages.removeAllObjects()
        unavailable.removeAllObjects()
        encodedDataCache.removeAllObjects()
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
        encodedDataCache.removeAllObjects()
    }

    // MARK: - Private

    /// 封面请求的来源服务器：显式传入优先（R01——播放器封面必须按歌曲真实服务器
    /// 路由，与当前浏览服务器无关）；否则回退当前浏览服务器；都没有视为本地。
    private func effectiveServerID(_ explicit: ServerID?) -> ServerID {
        explicit ?? currentServerID ?? ServerID(rawValue: "local")
    }

    /// 按请求来源服务器计算缓存键；磁盘缓存按服务器隔离，跨服务器同名 key 不串扰。
    private func cacheKey(_ remoteKey: String, targetPixelSize: Int, serverID: ServerID?) -> String {
        Self.cacheKey(
            namespace: effectiveServerID(serverID).rawValue,
            remoteKey: remoteKey,
            targetPixelSize: targetPixelSize
        )
    }

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

    private static func encodedCacheKey(namespace: String, remoteKey: String) -> String {
        "\(namespace)|\(remoteKey)"
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