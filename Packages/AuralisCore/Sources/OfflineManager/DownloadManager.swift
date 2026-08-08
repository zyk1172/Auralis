import Domain
import Foundation

/// 单曲下载任务状态。
public struct DownloadTaskInfo: Sendable, Equatable {
    public var trackID: TrackID
    public var status: DownloadStatus
    public var progress: Double
    public var byteCount: Int64

    public init(trackID: TrackID, status: DownloadStatus = .queued, progress: Double = 0, byteCount: Int64 = 0) {
        self.trackID = trackID
        self.status = status
        self.progress = progress
        self.byteCount = byteCount
    }
}

/// 带进度与取消的下载管理器。
/// 使用 URLSessionDownloadTask + delegate 汇报进度；完成后把临时文件移入 TrackCacheStore。
/// 线程安全：delegate 回调可能来自任意队列，内部用锁保护状态。
public final class DownloadManager: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    public typealias StateChange = @Sendable (TrackID, DownloadStatus, Double) -> Void

    /// delegate 必须指向 self，因此用 lazy 在 super.init 之后创建。
    /// 使用后台会话：App 被系统挂起后，下载任务按系统规则继续并在完成后回调
    /// `handleEventsForBackgroundURLSession`（由 App 生命周期转发）。
    /// 后台会话标识：App 生命周期转发 handleEventsForBackgroundURLSession 时按此匹配。
    public static let sessionIdentifier = "com.auralis.player.downloads"
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(
            withIdentifier: Self.sessionIdentifier
        )
        configuration.timeoutIntervalForRequest = 120
        configuration.sessionSendsLaunchEvents = true
        return URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
    }()
    private let store: TrackCacheStore
    /// 可替换的状态回调（App 在 init 完成后注入，避免 init 期捕获 self）。
    public var onStateChange: StateChange
    private let lock = NSLock()
    private var tasks: [TrackID: URLSessionDownloadTask] = [:]
    private var infos: [TrackID: DownloadTaskInfo] = [:]
    private var codecs: [TrackID: String] = [:]
    /// 下载任务归属的服务器（P0-1 缓存按服务器隔离：落盘必须带 serverID）。
    private var serverIDs: [TrackID: ServerID] = [:]
    /// 后台会话完成回调（handleEventsForBackgroundURLSession 传入，系统要求结束时调用）。
    private var backgroundCompletion: (() -> Void)?

    public init(
        store: TrackCacheStore,
        onStateChange: @escaping StateChange = { _, _, _ in }
    ) {
        self.store = store
        self.onStateChange = onStateChange
        super.init()
    }

    public func status(_ trackID: TrackID) -> DownloadTaskInfo? {
        lock.lock()
        defer { lock.unlock() }
        return infos[trackID]
    }

    public func isDownloading(_ trackID: TrackID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return tasks[trackID] != nil
    }

    public func activeCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return tasks.count
    }

    /// 开始下载：trackID → url（带认证的 download 地址）；serverID 用于落盘时按服务器隔离。
    public func start(trackID: TrackID, url: URL, codec: String?, serverID: ServerID) {
        lock.lock()
        guard tasks[trackID] == nil else {
            lock.unlock()
            return
        }
        infos[trackID] = DownloadTaskInfo(trackID: trackID, status: .downloading)
        codecs[trackID] = codec
        serverIDs[trackID] = serverID
        lock.unlock()

        let task = session.downloadTask(with: url)
        lock.lock()
        tasks[trackID] = task
        lock.unlock()
        onStateChange(trackID, .downloading, 0)
        task.resume()
    }

    public func cancel(_ trackID: TrackID) {
        lock.lock()
        let task = tasks.removeValue(forKey: trackID)
        infos[trackID] = DownloadTaskInfo(trackID: trackID, status: .notDownloaded)
        codecs[trackID] = nil
        serverIDs[trackID] = nil
        lock.unlock()
        task?.cancel()
        onStateChange(trackID, .notDownloaded, 0)
    }

    // MARK: - URLSessionDownloadDelegate

    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let trackID = trackID(for: downloadTask) else { return }
        let progress = totalBytesExpectedToWrite > 0
            ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            : 0
        lock.lock()
        infos[trackID]?.progress = min(max(progress, 0), 1)
        infos[trackID]?.byteCount = totalBytesWritten
        lock.unlock()
        onStateChange(trackID, .downloading, min(max(progress, 0), 1))
    }

    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let trackID = trackID(for: downloadTask) else { return }
        let codec: String?
        let serverID: ServerID?
        lock.lock()
        codec = codecs[trackID]
        serverID = serverIDs[trackID]
        tasks[trackID] = nil
        lock.unlock()
        guard let serverID else {
            finishFailure(trackID: trackID)
            return
        }
        // store 是 actor，moveDownloadedFile 需要 await；delegate 回调是同步的，用 Task 包裹。
        // 组合键带 serverID：不同服务器同 trackID 的文件互不覆盖（P0-1）。
        let cacheID = TrackCacheStore.TrackCacheID(serverID: serverID, trackID: trackID)
        Task { [store, cacheID, codec, location, self] in
            do {
                _ = try await store.moveDownloadedFile(at: location, for: cacheID, codec: codec)
                self.finishSuccess(trackID: trackID)
            } catch {
                self.finishFailure(trackID: trackID)
            }
        }
    }

    /// 同步辅助：完成状态更新（从异步上下文调用，锁在同步方法内执行）。
    private func finishSuccess(trackID: TrackID) {
        lock.lock()
        infos[trackID] = DownloadTaskInfo(trackID: trackID, status: .downloaded, progress: 1)
        codecs[trackID] = nil
        serverIDs[trackID] = nil
        lock.unlock()
        onStateChange(trackID, .downloaded, 1)
    }

    private func finishFailure(trackID: TrackID) {
        lock.lock()
        infos[trackID] = DownloadTaskInfo(trackID: trackID, status: .failed)
        codecs[trackID] = nil
        serverIDs[trackID] = nil
        lock.unlock()
        onStateChange(trackID, .failed, 0)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let trackID = trackID(for: task), error != nil else { return }
        lock.lock()
        let wasActive = tasks[trackID] != nil
        tasks[trackID] = nil
        lock.unlock()
        guard wasActive else { return }
        lock.lock()
        infos[trackID] = DownloadTaskInfo(trackID: trackID, status: .failed)
        codecs[trackID] = nil
        serverIDs[trackID] = nil
        lock.unlock()
        onStateChange(trackID, .failed, 0)
    }

    /// 由 App 生命周期转发：后台会话标识匹配时保存完成回调。
    /// 关键：必须**先访问 session（惰性创建）**，让系统把进程内既有后台任务重新连接到
    /// 本会话；否则 App 被系统拉起且没有新的 start() 时，session 从未创建，
    /// urlSessionDidFinishEvents 永不触发 → completion 不调用、挂起期间完成的下载
    /// 临时文件无法移入缓存，导致下载结果丢失。
    public func handleEventsForBackgroundURLSession(identifier: String, completion: @escaping () -> Void) {
        guard identifier == Self.sessionIdentifier else { return }
        _ = session
        lock.lock()
        backgroundCompletion = completion
        lock.unlock()
    }

    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        lock.lock()
        let completion = backgroundCompletion
        backgroundCompletion = nil
        lock.unlock()
        completion?()
    }

    private func trackID(for task: URLSessionTask) -> TrackID? {
        lock.lock()
        defer { lock.unlock() }
        return tasks.first { $0.value === task }?.key
    }
}
