import Application
import Foundation
import ImagePipeline

/// 封面管线返回值：压缩数据用于系统 Now Playing，解码结果用于界面显示。
struct ArtworkPipelinePayload: @unchecked Sendable {
    let decoded: DecodedArtwork
    let encodedData: Data
}

/// 封面的磁盘读取、网络回源、请求去重与后台解码管线。
///
/// 该 actor 不属于 MainActor。SwiftUI 只在最终得到 `DecodedArtwork` 后，
/// 才在主线程创建轻量的 UIImage / NSImage 包装对象。
actor ArtworkPipeline {
    private let connector: any ServerConnecting
    private let diskCache: ArtworkDiskCache
    private let decoder: ArtworkImageDecoder
    private let limiter: ArtworkRequestLimiter
    private var inFlight: [String: Task<ArtworkPipelinePayload?, Never>] = [:]

    init(
        connector: any ServerConnecting,
        diskCache: ArtworkDiskCache,
        decoder: ArtworkImageDecoder = ArtworkImageDecoder(),
        maximumNetworkRequests: Int = 6
    ) {
        self.connector = connector
        self.diskCache = diskCache
        self.decoder = decoder
        self.limiter = ArtworkRequestLimiter(limit: maximumNetworkRequests)
    }

    func load(
        remoteKey: String,
        cacheKey: String,
        fallbackCacheKey: String?,
        targetPixelSize: Int
    ) async -> ArtworkPipelinePayload? {
        if let existing = inFlight[cacheKey] {
            return await existing.value
        }

        let task = Task<ArtworkPipelinePayload?, Never> {
            if let data = await diskCache.data(for: cacheKey),
               let decoded = await decoder.decode(data, maxPixelSize: targetPixelSize) {
                return ArtworkPipelinePayload(decoded: decoded, encodedData: data)
            }

            if let fallbackCacheKey,
               fallbackCacheKey != cacheKey,
               let data = await diskCache.data(for: fallbackCacheKey),
               let decoded = await decoder.decode(data, maxPixelSize: targetPixelSize) {
                return ArtworkPipelinePayload(decoded: decoded, encodedData: data)
            }

            await limiter.acquire()
            guard !Task.isCancelled else {
                await limiter.release()
                return nil
            }
            let data = await connector.artworkData(
                key: remoteKey,
                targetPixelSize: max(1, targetPixelSize)
            )
            await limiter.release()

            guard !Task.isCancelled,
                  let data,
                  let decoded = await decoder.decode(data, maxPixelSize: targetPixelSize)
            else { return nil }

            await diskCache.store(data, for: cacheKey)
            return ArtworkPipelinePayload(decoded: decoded, encodedData: data)
        }

        inFlight[cacheKey] = task
        let result = await task.value
        inFlight[cacheKey] = nil
        return result
    }

    func cancelAll() {
        for task in inFlight.values { task.cancel() }
        inFlight.removeAll(keepingCapacity: true)
    }
}

/// 无轮询的协作式并发门，避免服务器离线时堆出几十个封面请求。
private actor ArtworkRequestLimiter {
    private let limit: Int
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    func acquire() async {
        if active < limit {
            active += 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if waiters.isEmpty {
            active = max(0, active - 1)
        } else {
            waiters.removeFirst().resume()
        }
    }
}
