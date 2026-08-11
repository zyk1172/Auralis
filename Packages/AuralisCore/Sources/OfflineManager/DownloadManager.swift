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

/// 下载任务在运行时的稳定身份。远端 TrackID 只在单台服务器内唯一，所有下载
/// 状态、回调和取消操作都必须同时携带 ServerID，避免多服务器相同 TrackID 串任务。
public struct DownloadTaskID: Hashable, Sendable {
    public let serverID: ServerID
    public let trackID: TrackID

    public init(serverID: ServerID, trackID: TrackID) {
        self.serverID = serverID
        self.trackID = trackID
    }
}

/// 可跨进程恢复的下载快照。业务层用服务器作用域重新建立 GlobalID，
/// 不再依赖只存在于 AppModel 内存中的 TrackID 映射。
public struct ActiveDownloadSnapshot: Sendable, Equatable {
    public let serverID: ServerID
    public let info: DownloadTaskInfo

    public init(serverID: ServerID, info: DownloadTaskInfo) {
        self.serverID = serverID
        self.info = info
    }
}

/// 带进度与取消的下载管理器。
/// 使用 URLSessionDownloadTask + delegate 汇报进度；完成后把临时文件移入 TrackCacheStore。
/// 线程安全：delegate 回调可能来自任意队列，内部用锁保护状态。
public final class DownloadManager: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    public typealias StateChange = @Sendable (DownloadTaskID, DownloadStatus, Double) -> Void

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
    private var tasks: [DownloadTaskID: URLSessionDownloadTask] = [:]
    private var infos: [DownloadTaskID: DownloadTaskInfo] = [:]
    private var codecs: [DownloadTaskID: String] = [:]
    /// taskIdentifier 在进程重启后仍可由后台 URLSession 恢复；同时也覆盖“文件已下载、正搬入缓存”的窗口。
    private var taskIdentifiers: [DownloadTaskID: Int] = [:]
    /// `getAllTasks` 的异步快照可能晚于用户取消返回。用 taskIdentifier 墓碑阻止恢复回调
    /// 把已经取消的系统任务重新绑定成 downloading；消费后立即移除，集合保持有界。
    private var cancelledTaskIdentifiers: Set<Int> = []
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

    public func status(_ id: DownloadTaskID) -> DownloadTaskInfo? {
        lock.lock()
        defer { lock.unlock() }
        return infos[id]
    }

    public func isDownloading(_ id: DownloadTaskID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return taskIdentifiers[id] != nil
    }

    /// 旧调用方兼容查询。仅在同一 TrackID 恰好对应一个服务器任务时返回状态；
    /// 新代码必须使用带 ServerID 的 DownloadTaskID，避免结果含糊。
    public func status(_ trackID: TrackID) -> DownloadTaskInfo? {
        lock.lock()
        defer { lock.unlock() }
        let matches = infos.filter { $0.key.trackID == trackID }
        guard matches.count == 1 else { return nil }
        return matches.first?.value
    }

    /// 旧调用方兼容查询：任意服务器存在该 TrackID 的活动任务即返回 true。
    public func isDownloading(_ trackID: TrackID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return taskIdentifiers.keys.contains { $0.trackID == trackID }
    }

    public func activeCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return taskIdentifiers.count
    }

    /// 返回持久化任务恢复后的服务器作用域状态。该接口不包含 URL 或认证信息。
    public func activeSnapshots() -> [ActiveDownloadSnapshot] {
        lock.lock()
        defer { lock.unlock() }
        return taskIdentifiers.keys.compactMap { id in
            guard let info = infos[id] else { return nil }
            return ActiveDownloadSnapshot(serverID: id.serverID, info: info)
        }
    }

    /// 开始下载：trackID → url（带认证的 download 地址）；serverID 用于落盘时按服务器隔离。
    public func start(trackID: TrackID, url: URL, codec: String?, serverID: ServerID) {
        let id = DownloadTaskID(serverID: serverID, trackID: trackID)
        lock.lock()
        guard taskIdentifiers[id] == nil else {
            lock.unlock()
            return
        }
        infos[id] = DownloadTaskInfo(trackID: trackID, status: .downloading)
        codecs[id] = codec
        lock.unlock()

        let task = session.downloadTask(with: url)
        let metadata = DownloadTaskMetadata(trackID: trackID, serverID: serverID, codec: codec)
        task.taskDescription = metadata.taskDescription
        lock.lock()
        tasks[id] = task
        taskIdentifiers[id] = task.taskIdentifier
        lock.unlock()
        // 必须在 resume 前写入兜底映射，避免任务刚启动进程就被系统终止的竞态。
        metadataStore.save(metadata, for: task.taskIdentifier)
        onStateChange(id, .downloading, 0)
        task.resume()
    }

    public func cancel(_ id: DownloadTaskID) {
        lock.lock()
        let task = tasks.removeValue(forKey: id)
        let taskIdentifier = taskIdentifiers.removeValue(forKey: id)
        if let taskIdentifier {
            cancelledTaskIdentifiers.insert(taskIdentifier)
            if cancelledTaskIdentifiers.count > 256,
               let oldestUnknown = cancelledTaskIdentifiers.first(where: { $0 != taskIdentifier }) {
                cancelledTaskIdentifiers.remove(oldestUnknown)
            }
        }
        infos[id] = DownloadTaskInfo(trackID: id.trackID, status: .notDownloaded)
        codecs[id] = nil
        lock.unlock()
        task?.taskDescription = nil
        if let taskIdentifier {
            metadataStore.remove(taskIdentifier: taskIdentifier)
        }
        task?.cancel()
        onStateChange(id, .notDownloaded, 0)
    }

    /// 旧调用方兼容取消：取消所有匹配的服务器任务。业务代码应使用 scoped 版本。
    public func cancel(_ trackID: TrackID) {
        lock.lock()
        let ids = taskIdentifiers.keys.filter { $0.trackID == trackID }
        lock.unlock()
        for id in ids { cancel(id) }
    }

    // MARK: - URLSessionDownloadDelegate

    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let id = taskID(for: downloadTask) else { return }
        let progress = totalBytesExpectedToWrite > 0
            ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            : 0
        lock.lock()
        infos[id]?.progress = min(max(progress, 0), 1)
        infos[id]?.byteCount = totalBytesWritten
        lock.unlock()
        onStateChange(id, .downloading, min(max(progress, 0), 1))
    }

    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let id = taskID(for: downloadTask) else { return }
        let codec: String?
        let taskIdentifier: Int
        lock.lock()
        codec = codecs[id]
        tasks[id] = nil
        taskIdentifier = taskIdentifiers[id] ?? downloadTask.taskIdentifier
        pendingCacheMoves += 1
        lock.unlock()
        // store 是 actor，moveDownloadedFile 需要 await；delegate 回调是同步的，用 Task 包裹。
        // 组合键带 serverID：不同服务器同 trackID 的文件互不覆盖（P0-1）。
        let cacheID = TrackCacheStore.TrackCacheID(serverID: id.serverID, trackID: id.trackID)
        Task { [store, cacheID, codec, location, self] in
            do {
                _ = try await store.moveDownloadedFile(at: location, for: cacheID, codec: codec)
                self.finishSuccess(id: id, taskIdentifier: taskIdentifier)
            } catch {
                self.finishFailure(id: id, taskIdentifier: taskIdentifier)
            }
            self.finishPendingCacheMove()
        }
    }

    /// 同步辅助：完成状态更新（从异步上下文调用，锁在同步方法内执行）。
    private func finishSuccess(id: DownloadTaskID, taskIdentifier: Int) {
        lock.lock()
        infos[id] = DownloadTaskInfo(trackID: id.trackID, status: .downloaded, progress: 1)
        codecs[id] = nil
        taskIdentifiers[id] = nil
        lock.unlock()
        metadataStore.remove(taskIdentifier: taskIdentifier)
        onStateChange(id, .downloaded, 1)
    }

    private func finishFailure(id: DownloadTaskID, taskIdentifier: Int) {
        lock.lock()
        infos[id] = DownloadTaskInfo(trackID: id.trackID, status: .failed)
        codecs[id] = nil
        taskIdentifiers[id] = nil
        lock.unlock()
        metadataStore.remove(taskIdentifier: taskIdentifier)
        onStateChange(id, .failed, 0)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let id = taskID(for: task), error != nil else { return }
        lock.lock()
        let wasActive = tasks[id] != nil
        tasks[id] = nil
        let taskIdentifier = taskIdentifiers.removeValue(forKey: id) ?? task.taskIdentifier
        lock.unlock()
        guard wasActive else { return }
        lock.lock()
        infos[id] = DownloadTaskInfo(trackID: id.trackID, status: .failed)
        codecs[id] = nil
        lock.unlock()
        metadataStore.remove(taskIdentifier: taskIdentifier)
        onStateChange(id, .failed, 0)
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

    private func taskID(for task: URLSessionTask) -> DownloadTaskID? {
        lock.lock()
        let inMemoryID = tasks.first { $0.value === task }?.key
        lock.unlock()
        if let inMemoryID { return inMemoryID }

        guard
            let downloadTask = task as? URLSessionDownloadTask,
            let metadata = metadata(for: downloadTask)
        else { return nil }
        bind(task: downloadTask, metadata: metadata)
        return DownloadTaskID(serverID: metadata.serverID, trackID: metadata.trackID)
    }

    private func metadata(for task: URLSessionTask) -> DownloadTaskMetadata? {
        DownloadTaskMetadata.decode(taskDescription: task.taskDescription)
            ?? metadataStore.metadata(for: task.taskIdentifier)
    }

    private func hydratePersistedTaskState() {
        let persisted = metadataStore.all()
        lock.lock()
        for (taskIdentifier, metadata) in persisted {
            let id = DownloadTaskID(serverID: metadata.serverID, trackID: metadata.trackID)
            infos[id] = DownloadTaskInfo(trackID: metadata.trackID, status: .downloading)
            codecs[id] = metadata.codec
            taskIdentifiers[id] = taskIdentifier
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
            lock.lock()
            let wasCancelled = cancelledTaskIdentifiers.remove(downloadTask.taskIdentifier) != nil
            lock.unlock()
            if wasCancelled {
                downloadTask.taskDescription = nil
                metadataStore.remove(taskIdentifier: downloadTask.taskIdentifier)
                downloadTask.cancel()
                continue
            }
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
        var failedIDs: [DownloadTaskID] = []
        for taskIdentifier in staleTaskIdentifiers {
            guard let metadata = metadataStore.metadata(for: taskIdentifier) else { continue }
            metadataStore.remove(taskIdentifier: taskIdentifier)
            let id = DownloadTaskID(serverID: metadata.serverID, trackID: metadata.trackID)
            lock.lock()
            if taskIdentifiers[id] == taskIdentifier {
                taskIdentifiers[id] = nil
                codecs[id] = nil
                infos[id] = DownloadTaskInfo(trackID: metadata.trackID, status: .failed)
                failedIDs.append(id)
            }
            lock.unlock()
        }
        for id in failedIDs {
            onStateChange(id, .failed, 0)
        }
    }

    private func bind(task: URLSessionDownloadTask, metadata: DownloadTaskMetadata) {
        let id = DownloadTaskID(serverID: metadata.serverID, trackID: metadata.trackID)
        lock.lock()
        // 同一服务器的同一首歌只允许一个系统任务；不同服务器的相同 TrackID 可并存。
        if let existingIdentifier = taskIdentifiers[id],
           existingIdentifier != task.taskIdentifier,
           let existingTask = tasks[id],
           existingTask !== task {
            lock.unlock()
            task.taskDescription = nil
            metadataStore.remove(taskIdentifier: task.taskIdentifier)
            task.cancel()
            return
        }
        tasks[id] = task
        taskIdentifiers[id] = task.taskIdentifier
        infos[id] = DownloadTaskInfo(trackID: metadata.trackID, status: .downloading)
        codecs[id] = metadata.codec
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
