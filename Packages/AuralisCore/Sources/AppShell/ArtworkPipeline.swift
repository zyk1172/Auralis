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

            guard await limiter.acquire() else {
                // 排队期间被取消（封面已滚出屏幕）——直接让路。
                return nil
            }
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

            // 磁盘写入不阻塞首屏显示：先让用户看到图片，再慢慢落盘。
            let payload = ArtworkPipelinePayload(decoded: decoded, encodedData: data)
            Task(priority: .utility) { [diskCache] in
                await diskCache.store(data, for: cacheKey)
            }
            return payload
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
///
/// cancellation-aware：等待队列按 UUID 登记，任务被取消（封面滚出屏幕、
/// SwiftUI task 已 cancel）时立即让出队列，不再排在那些无意义请求后面，
/// 让当前屏幕上的封面真正插队。
private actor ArtworkRequestLimiter {
    private let limit: Int
    private var active = 0
    private var waiterOrder: [UUID] = []
    private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    /// 获取一个并发名额。返回 `false` 表示排队期间任务已被取消。
    func acquire() async -> Bool {
        if active < limit {
            active += 1
            return true
        }
        let id = UUID()
        waiterOrder.append(id)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                waiters[id] = continuation
                // 防御：若取消在注册前已把 id 移出队列，直接恢复 false。
                if !waiterOrder.contains(id) {
                    waiters.removeValue(forKey: id)
                    continuation.resume(returning: false)
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    func release() {
        if waiters.isEmpty {
            active = max(0, active - 1)
        } else {
            let id = waiterOrder.removeFirst()
            waiters.removeValue(forKey: id)?.resume(returning: true)
        }
    }

    private func cancelWaiter(_ id: UUID) {
        if let index = waiterOrder.firstIndex(of: id) {
            waiterOrder.remove(at: index)
        }
        if let continuation = waiters.removeValue(forKey: id) {
            continuation.resume(returning: false)
        }
    }
}
