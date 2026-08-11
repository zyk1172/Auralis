import Domain
import Foundation

/// 后台 URLSession 任务自身携带的稳定业务身份。
///
/// `URLSessionTask.taskIdentifier` 只能标识系统会话里的任务，App 进程被系统终止后，
/// 原先的 Swift 对象身份和内存字典都会丢失。因此业务身份同时写入 taskDescription
/// 和 UserDefaults：前者随后台任务由系统保存，后者用于兼容 taskDescription 缺失或旧系统恢复异常。
struct DownloadTaskMetadata: Codable, Equatable, Sendable {
    static let descriptionPrefix = "auralis.download.v1:"

    let trackID: TrackID
    let serverID: ServerID
    let codec: String?

    var taskDescription: String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return Self.descriptionPrefix + data.base64EncodedString()
    }

    static func decode(taskDescription: String?) -> Self? {
        guard
            let taskDescription,
            taskDescription.hasPrefix(descriptionPrefix),
            let data = Data(base64Encoded: String(taskDescription.dropFirst(descriptionPrefix.count)))
        else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
}

/// 很小的任务身份仓库。只保存 track/server/codec，不保存下载 URL 或认证参数。
/// 使用整份 JSON 原子覆盖，任务数通常很少，且避免多个独立 key 留下半写状态。
final class DownloadTaskMetadataStore: @unchecked Sendable {
    private static let storageKey = "com.auralis.player.download-task-metadata.v1"
    static let shared = DownloadTaskMetadataStore(defaults: .standard)

    private let defaults: UserDefaults
    private let key: String
    private let lock = NSLock()

    init(defaults: UserDefaults, key: String = storageKey) {
        self.defaults = defaults
        self.key = key
    }

    func all() -> [Int: DownloadTaskMetadata] {
        lock.lock()
        defer { lock.unlock() }
        return loadLocked()
    }

    func metadata(for taskIdentifier: Int) -> DownloadTaskMetadata? {
        lock.lock()
        defer { lock.unlock() }
        return loadLocked()[taskIdentifier]
    }

    func save(_ metadata: DownloadTaskMetadata, for taskIdentifier: Int) {
        lock.lock()
        var records = loadLocked()
        records[taskIdentifier] = metadata
        saveLocked(records)
        lock.unlock()
    }

    func remove(taskIdentifier: Int) {
        lock.lock()
        var records = loadLocked()
        records[taskIdentifier] = nil
        saveLocked(records)
        lock.unlock()
    }

    private func loadLocked() -> [Int: DownloadTaskMetadata] {
        guard
            let data = defaults.data(forKey: key),
            let stored = try? JSONDecoder().decode([String: DownloadTaskMetadata].self, from: data)
        else { return [:] }
        return Dictionary(uniqueKeysWithValues: stored.compactMap { key, value in
            guard let identifier = Int(key) else { return nil }
            return (identifier, value)
        })
    }

    private func saveLocked(_ records: [Int: DownloadTaskMetadata]) {
        guard !records.isEmpty else {
            defaults.removeObject(forKey: key)
            return
        }
        let stored = Dictionary(uniqueKeysWithValues: records.map { (String($0.key), $0.value) })
        if let data = try? JSONEncoder().encode(stored) {
            defaults.set(data, forKey: key)
        }
    }
}

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
    private let metadataStore: DownloadTaskMetadataStore
    /// 可替换的状态回调（App 在 init 完成后注入，避免 init 期捕获 self）。
    public var onStateChange: StateChange
    private let lock = NSLock()
    private var tasks: [TrackID: URLSessionDownloadTask] = [:]
    private var infos: [TrackID: DownloadTaskInfo] = [:]
    private var codecs: [TrackID: String] = [:]
    /// 下载任务归属的服务器（P0-1 缓存按服务器隔离：落盘必须带 serverID）。
    private var serverIDs: [TrackID: ServerID] = [:]
    /// taskIdentifier 在进程重启后仍可由后台 URLSession 恢复；同时也覆盖“文件已下载、正搬入缓存”的窗口。
    private var taskIdentifiers: [TrackID: Int] = [:]
    /// URLSession 的事件结束不代表异步缓存搬运已经结束，必须等两者都结束再交还系统 completion。
    private var pendingCacheMoves = 0
    private var backgroundSessionEventsFinished = false
    /// 后台会话完成回调（handleEventsForBackgroundURLSession 传入，系统要求结束时调用）。
    private var backgroundCompletion: (() -> Void)?

    public convenience init(
        store: TrackCacheStore,
        onStateChange: @escaping StateChange = { _, _, _ in }
    ) {
        self.init(
            store: store,
            onStateChange: onStateChange,
            metadataStore: .shared,
            automaticallyReconnect: true
        )
    }

    init(
        store: TrackCacheStore,
        onStateChange: @escaping StateChange = { _, _, _ in },
        metadataStore: DownloadTaskMetadataStore,
        automaticallyReconnect: Bool
    ) {
        self.store = store
        self.onStateChange = onStateChange
        self.metadataStore = metadataStore
        super.init()
        hydratePersistedTaskState()
        if automaticallyReconnect {
            reconnectBackgroundTasks()
        }
    }

    public func status(_ trackID: TrackID) -> DownloadTaskInfo? {
        lock.lock()
        defer { lock.unlock() }
        return infos[trackID]
    }

    public func isDownloading(_ trackID: TrackID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return taskIdentifiers[trackID] != nil
    }

    public func activeCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return taskIdentifiers.count
    }

    /// 开始下载：trackID → url（带认证的 download 地址）；serverID 用于落盘时按服务器隔离。
    public func start(trackID: TrackID, url: URL, codec: String?, serverID: ServerID) {
        lock.lock()
        guard taskIdentifiers[trackID] == nil else {
            lock.unlock()
            return
        }
        infos[trackID] = DownloadTaskInfo(trackID: trackID, status: .downloading)
        codecs[trackID] = codec
        serverIDs[trackID] = serverID
        lock.unlock()

        let task = session.downloadTask(with: url)
        let metadata = DownloadTaskMetadata(trackID: trackID, serverID: serverID, codec: codec)
        task.taskDescription = metadata.taskDescription
        lock.lock()
        tasks[trackID] = task
        taskIdentifiers[trackID] = task.taskIdentifier
        lock.unlock()
        // 必须在 resume 前写入兜底映射，避免任务刚启动进程就被系统终止的竞态。
        metadataStore.save(metadata, for: task.taskIdentifier)
        onStateChange(trackID, .downloading, 0)
        task.resume()
    }

    public func cancel(_ trackID: TrackID) {
        lock.lock()
        let task = tasks.removeValue(forKey: trackID)
        let taskIdentifier = taskIdentifiers.removeValue(forKey: trackID)
        infos[trackID] = DownloadTaskInfo(trackID: trackID, status: .notDownloaded)
        codecs[trackID] = nil
        serverIDs[trackID] = nil
        lock.unlock()
        task?.taskDescription = nil
        if let taskIdentifier {
            metadataStore.remove(taskIdentifier: taskIdentifier)
        }
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
        let taskIdentifier: Int
        lock.lock()
        codec = codecs[trackID]
        serverID = serverIDs[trackID]
        tasks[trackID] = nil
        taskIdentifier = taskIdentifiers[trackID] ?? downloadTask.taskIdentifier
        pendingCacheMoves += 1
        lock.unlock()
        guard let serverID else {
            finishFailure(trackID: trackID, taskIdentifier: taskIdentifier)
            finishPendingCacheMove()
            return
        }
        // store 是 actor，moveDownloadedFile 需要 await；delegate 回调是同步的，用 Task 包裹。
        // 组合键带 serverID：不同服务器同 trackID 的文件互不覆盖（P0-1）。
        let cacheID = TrackCacheStore.TrackCacheID(serverID: serverID, trackID: trackID)
        Task { [store, cacheID, codec, location, self] in
            do {
                _ = try await store.moveDownloadedFile(at: location, for: cacheID, codec: codec)
                self.finishSuccess(trackID: trackID, taskIdentifier: taskIdentifier)
            } catch {
                self.finishFailure(trackID: trackID, taskIdentifier: taskIdentifier)
            }
            self.finishPendingCacheMove()
        }
    }

    /// 同步辅助：完成状态更新（从异步上下文调用，锁在同步方法内执行）。
    private func finishSuccess(trackID: TrackID, taskIdentifier: Int) {
        lock.lock()
        infos[trackID] = DownloadTaskInfo(trackID: trackID, status: .downloaded, progress: 1)
        codecs[trackID] = nil
        serverIDs[trackID] = nil
        taskIdentifiers[trackID] = nil
        lock.unlock()
        metadataStore.remove(taskIdentifier: taskIdentifier)
        onStateChange(trackID, .downloaded, 1)
    }

    private func finishFailure(trackID: TrackID, taskIdentifier: Int) {
        lock.lock()
        infos[trackID] = DownloadTaskInfo(trackID: trackID, status: .failed)
        codecs[trackID] = nil
        serverIDs[trackID] = nil
        taskIdentifiers[trackID] = nil
        lock.unlock()
        metadataStore.remove(taskIdentifier: taskIdentifier)
        onStateChange(trackID, .failed, 0)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let trackID = trackID(for: task), error != nil else { return }
        lock.lock()
        let wasActive = tasks[trackID] != nil
        tasks[trackID] = nil
        let taskIdentifier = taskIdentifiers.removeValue(forKey: trackID) ?? task.taskIdentifier
        lock.unlock()
        guard wasActive else { return }
        lock.lock()
        infos[trackID] = DownloadTaskInfo(trackID: trackID, status: .failed)
        codecs[trackID] = nil
        serverIDs[trackID] = nil
        lock.unlock()
        metadataStore.remove(taskIdentifier: taskIdentifier)
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
        let completionToCall = takeBackgroundCompletionIfReadyLocked()
        lock.unlock()
        reconnectBackgroundTasks()
        completionToCall?()
    }

    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        lock.lock()
        backgroundSessionEventsFinished = true
        let completion = takeBackgroundCompletionIfReadyLocked()
        lock.unlock()
        completion?()
    }

    private func trackID(for task: URLSessionTask) -> TrackID? {
        lock.lock()
        let inMemoryTrackID = tasks.first { $0.value === task }?.key
        lock.unlock()
        if let inMemoryTrackID { return inMemoryTrackID }

        guard
            let downloadTask = task as? URLSessionDownloadTask,
            let metadata = metadata(for: downloadTask)
        else { return nil }
        bind(task: downloadTask, metadata: metadata)
        return metadata.trackID
    }

    private func metadata(for task: URLSessionTask) -> DownloadTaskMetadata? {
        DownloadTaskMetadata.decode(taskDescription: task.taskDescription)
            ?? metadataStore.metadata(for: task.taskIdentifier)
    }

    private func hydratePersistedTaskState() {
        let persisted = metadataStore.all()
        lock.lock()
        for (taskIdentifier, metadata) in persisted {
            infos[metadata.trackID] = DownloadTaskInfo(trackID: metadata.trackID, status: .downloading)
            codecs[metadata.trackID] = metadata.codec
            serverIDs[metadata.trackID] = metadata.serverID
            taskIdentifiers[metadata.trackID] = taskIdentifier
        }
        lock.unlock()
    }

    /// 重新连接系统后台会话，并用 taskDescription / 持久映射重建内存状态。
    private func reconnectBackgroundTasks() {
        let pruneCandidates = Set(metadataStore.all().keys)
        session.getAllTasks { [weak self] existingTasks in
            self?.restore(existingTasks: existingTasks, pruneCandidates: pruneCandidates)
        }
    }

    private func restore(existingTasks: [URLSessionTask], pruneCandidates: Set<Int>) {
        var activeTaskIdentifiers = Set<Int>()
        for task in existingTasks {
            guard let downloadTask = task as? URLSessionDownloadTask else { continue }
            guard let metadata = metadata(for: downloadTask) else {
                // 这是 Auralis 专用后台会话；无法恢复业务身份的孤儿任务即使完成也无法安全落盘。
                downloadTask.cancel()
                continue
            }
            activeTaskIdentifiers.insert(downloadTask.taskIdentifier)
            if downloadTask.taskDescription == nil {
                downloadTask.taskDescription = metadata.taskDescription
            }
            metadataStore.save(metadata, for: downloadTask.taskIdentifier)
            bind(task: downloadTask, metadata: metadata)
            if downloadTask.state == .suspended {
                downloadTask.resume()
            }
        }

        // 只清理 getAllTasks 调用前已经存在的记录，避免与同时发生的新 start() 竞争。
        let staleTaskIdentifiers = pruneCandidates.subtracting(activeTaskIdentifiers)
        var failedTrackIDs: [TrackID] = []
        for taskIdentifier in staleTaskIdentifiers {
            guard let metadata = metadataStore.metadata(for: taskIdentifier) else { continue }
            metadataStore.remove(taskIdentifier: taskIdentifier)
            lock.lock()
            if taskIdentifiers[metadata.trackID] == taskIdentifier {
                taskIdentifiers[metadata.trackID] = nil
                codecs[metadata.trackID] = nil
                serverIDs[metadata.trackID] = nil
                infos[metadata.trackID] = DownloadTaskInfo(trackID: metadata.trackID, status: .failed)
                failedTrackIDs.append(metadata.trackID)
            }
            lock.unlock()
        }
        for trackID in failedTrackIDs {
            onStateChange(trackID, .failed, 0)
        }
    }

    private func bind(task: URLSessionDownloadTask, metadata: DownloadTaskMetadata) {
        lock.lock()
        // start() 本来就禁止同一首歌重复下载；恢复时也只认同一 track 的一个系统任务。
        if let existingIdentifier = taskIdentifiers[metadata.trackID],
           existingIdentifier != task.taskIdentifier,
           let existingTask = tasks[metadata.trackID],
           existingTask !== task {
            lock.unlock()
            task.taskDescription = nil
            metadataStore.remove(taskIdentifier: task.taskIdentifier)
            task.cancel()
            return
        }
        tasks[metadata.trackID] = task
        taskIdentifiers[metadata.trackID] = task.taskIdentifier
        infos[metadata.trackID] = DownloadTaskInfo(trackID: metadata.trackID, status: .downloading)
        codecs[metadata.trackID] = metadata.codec
        serverIDs[metadata.trackID] = metadata.serverID
        lock.unlock()
    }

    private func finishPendingCacheMove() {
        lock.lock()
        pendingCacheMoves = max(pendingCacheMoves - 1, 0)
        let completion = takeBackgroundCompletionIfReadyLocked()
        lock.unlock()
        completion?()
    }

    /// 仅在持锁时调用；completion 必须在解锁后执行。
    private func takeBackgroundCompletionIfReadyLocked() -> (() -> Void)? {
        guard
            backgroundSessionEventsFinished,
            pendingCacheMoves == 0,
            let completion = backgroundCompletion
        else { return nil }
        backgroundCompletion = nil
        backgroundSessionEventsFinished = false
        return completion
    }

    // 测试入口：验证真实恢复算法，而不是只测独立的 JSON helper。
    func restoreForTesting(existingTasks: [URLSessionTask], pruneCandidates: Set<Int> = []) {
        restore(existingTasks: existingTasks, pruneCandidates: pruneCandidates)
    }
}
