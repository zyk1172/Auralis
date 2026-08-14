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

private struct PersistedDownloadFailure: Codable, Equatable, Sendable {
    let metadata: DownloadTaskMetadata
    let info: DownloadTaskInfo
}

/// 很小的任务身份仓库。只保存 track/server/codec，不保存下载 URL 或认证参数。
/// 使用整份 JSON 原子覆盖，任务数通常很少，且避免多个独立 key 留下半写状态。
final class DownloadTaskMetadataStore: @unchecked Sendable {
    private static let storageKey = "com.auralis.player.download-task-metadata.v1"
    static let shared = DownloadTaskMetadataStore(defaults: .standard)

    private let defaults: UserDefaults
    private let key: String
    private let failuresKey: String
    private let lock = NSLock()

    init(defaults: UserDefaults, key: String = storageKey) {
        self.defaults = defaults
        self.key = key
        self.failuresKey = key + ".failures"
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

    func failures() -> [(DownloadTaskID, DownloadTaskInfo)] {
        lock.lock()
        defer { lock.unlock() }
        return loadFailuresLocked().map {
            (
                DownloadTaskID(serverID: $0.metadata.serverID, trackID: $0.metadata.trackID),
                $0.info
            )
        }
    }

    func saveFailure(id: DownloadTaskID, info: DownloadTaskInfo, codec: String?) {
        lock.lock()
        var failures = loadFailuresLocked()
        let metadata = DownloadTaskMetadata(trackID: id.trackID, serverID: id.serverID, codec: codec)
        failures.removeAll {
            $0.metadata.serverID == id.serverID && $0.metadata.trackID == id.trackID
        }
        failures.append(PersistedDownloadFailure(metadata: metadata, info: info))
        saveFailuresLocked(failures)
        lock.unlock()
    }

    func removeFailure(id: DownloadTaskID) {
        lock.lock()
        var failures = loadFailuresLocked()
        failures.removeAll {
            $0.metadata.serverID == id.serverID && $0.metadata.trackID == id.trackID
        }
        saveFailuresLocked(failures)
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

    private func loadFailuresLocked() -> [PersistedDownloadFailure] {
        guard let data = defaults.data(forKey: failuresKey) else { return [] }
        return (try? JSONDecoder().decode([PersistedDownloadFailure].self, from: data)) ?? []
    }

    private func saveFailuresLocked(_ failures: [PersistedDownloadFailure]) {
        guard !failures.isEmpty else {
            defaults.removeObject(forKey: failuresKey)
            return
        }
        if let data = try? JSONEncoder().encode(failures) {
            defaults.set(data, forKey: failuresKey)
        }
    }
}

/// 单曲下载任务状态。
public struct DownloadTaskInfo: Codable, Sendable, Equatable {
    public var trackID: TrackID
    public var status: DownloadStatus
    public var progress: Double
    public var byteCount: Int64
    public var expectedByteCount: Int64?
    public var failure: DownloadFailureInfo?

    public init(
        trackID: TrackID,
        status: DownloadStatus = .queued,
        progress: Double = 0,
        byteCount: Int64 = 0,
        expectedByteCount: Int64? = nil,
        failure: DownloadFailureInfo? = nil
    ) {
        self.trackID = trackID
        self.status = status
        self.progress = progress
        self.byteCount = byteCount
        self.expectedByteCount = expectedByteCount
        self.failure = failure
    }
}

/// 可稳定展示、测试和重试决策的失败分类。不要把带认证参数的 URL 或系统错误原文
/// 直接暴露给 UI；这里只保存面向用户的脱敏说明。
public enum DownloadFailureKind: String, Codable, Hashable, Sendable {
    case networkUnavailable
    case timedOut
    case authentication
    case unavailable
    case invalidResponse
    case storage
    case interrupted
    case unknown
}

public struct DownloadFailureInfo: Codable, Hashable, Sendable {
    public let kind: DownloadFailureKind
    public let message: String

    public init(kind: DownloadFailureKind, message: String) {
        self.kind = kind
        self.message = message
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
    public typealias StateChange = @Sendable (DownloadTaskID, DownloadTaskInfo) -> Void

    /// delegate 必须指向 self，因此用 lazy 在 super.init 之后创建。
    /// 使用后台会话：App 被系统挂起后，下载任务按系统规则继续并在完成后回调
    /// `handleEventsForBackgroundURLSession`（由 App 生命周期转发）。
    /// 后台会话标识：App 生命周期转发 handleEventsForBackgroundURLSession 时按此匹配。
    public static let sessionIdentifier = "com.auralis.player.downloads"
    private lazy var session: URLSession = {
        let configuration = sessionConfiguration
        configuration.timeoutIntervalForRequest = 120
        if configuration.identifier != nil {
            configuration.sessionSendsLaunchEvents = true
        }
        return URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
    }()
    private let sessionConfiguration: URLSessionConfiguration
    private let store: TrackCacheStore
    private let metadataStore: DownloadTaskMetadataStore
    private let maxConcurrentDownloads: Int
    private let stagingDirectory: URL
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
    /// didFinishDownloadingTo 提供的系统临时文件只在 delegate 回调期间有效。
    /// 先同步移到 staging，再跨 actor 写入正式缓存；这里记录崩溃恢复中的文件。
    private var recoveringTaskIdentifiers: Set<Int> = []
    /// URLSession 的事件结束不代表异步缓存搬运已经结束，必须等两者都结束再交还系统 completion。
    private var pendingCacheMoves = 0
    private var backgroundSessionEventsFinished = false
    /// 后台会话完成回调（handleEventsForBackgroundURLSession 传入，系统要求结束时调用）。
    private var backgroundCompletion: (() -> Void)?

    public convenience init(
        store: TrackCacheStore,
        maxConcurrentDownloads: Int = 3,
        onStateChange: @escaping StateChange = { _, _ in }
    ) {
        self.init(
            store: store,
            maxConcurrentDownloads: maxConcurrentDownloads,
            onStateChange: onStateChange,
            metadataStore: .shared,
            automaticallyReconnect: true
        )
    }

    init(
        store: TrackCacheStore,
        maxConcurrentDownloads: Int = 3,
        onStateChange: @escaping StateChange = { _, _ in },
        metadataStore: DownloadTaskMetadataStore,
        automaticallyReconnect: Bool,
        stagingDirectory: URL? = nil,
        sessionConfiguration: URLSessionConfiguration? = nil
    ) {
        self.store = store
        self.maxConcurrentDownloads = max(1, maxConcurrentDownloads)
        self.onStateChange = onStateChange
        self.metadataStore = metadataStore
        self.sessionConfiguration = sessionConfiguration ?? URLSessionConfiguration.background(
            withIdentifier: Self.sessionIdentifier
        )
        self.stagingDirectory = stagingDirectory ?? Self.makeStagingDirectory()
        try? FileManager.default.createDirectory(at: self.stagingDirectory, withIntermediateDirectories: true)
        super.init()
        hydratePersistedTaskState()
        recoverStagedDownloads()
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

    /// 包含活动任务与持久化失败记录，供 App 冷启动后恢复“可重试”状态。
    public func stateSnapshots() -> [ActiveDownloadSnapshot] {
        lock.lock()
        defer { lock.unlock() }
        return infos.map { id, info in ActiveDownloadSnapshot(serverID: id.serverID, info: info) }
    }

    /// 开始下载：trackID → url（带认证的 download 地址）；serverID 用于落盘时按服务器隔离。
    public func start(trackID: TrackID, url: URL, codec: String?, serverID: ServerID) {
        let id = DownloadTaskID(serverID: serverID, trackID: trackID)
        metadataStore.removeFailure(id: id)
        lock.lock()
        guard taskIdentifiers[id] == nil else {
            lock.unlock()
            return
        }
        infos[id] = DownloadTaskInfo(trackID: trackID, status: .queued)
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
        notify(id)
        resumeNextTasks()
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
        metadataStore.removeFailure(id: id)
        task?.cancel()
        notify(id)
        resumeNextTasks()
    }

    /// 旧调用方兼容取消：取消所有匹配的服务器任务。业务代码应使用 scoped 版本。
    public func cancel(_ trackID: TrackID) {
        lock.lock()
        let ids = taskIdentifiers.keys.filter { $0.trackID == trackID }
        lock.unlock()
        for id in ids { cancel(id) }
    }

    public func cancelAll() {
        lock.lock()
        let ids = Array(taskIdentifiers.keys)
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
        infos[id]?.expectedByteCount = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil
        infos[id]?.failure = nil
        lock.unlock()
        notify(id)
    }

    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let id = taskID(for: downloadTask) else { return }
        lock.lock()
        let isAlreadyRecovering = recoveringTaskIdentifiers.contains(downloadTask.taskIdentifier)
        lock.unlock()
        guard !isAlreadyRecovering else { return }
        if let failure = Self.responseFailure(for: downloadTask) {
            finishFailure(id: id, taskIdentifier: downloadTask.taskIdentifier, failure: failure)
            resumeNextTasks()
            return
        }
        let downloadedBytes = Self.fileSize(at: location)
        guard downloadedBytes > 0 else {
            finishFailure(
                id: id,
                taskIdentifier: downloadTask.taskIdentifier,
                failure: DownloadFailureInfo(kind: .invalidResponse, message: "服务器返回了空文件，请重试")
            )
            resumeNextTasks()
            return
        }
        let stagedLocation: URL
        do {
            stagedLocation = try stageTemporaryDownload(at: location, taskIdentifier: downloadTask.taskIdentifier)
        } catch {
            finishFailure(
                id: id,
                taskIdentifier: downloadTask.taskIdentifier,
                failure: DownloadFailureInfo(kind: .storage, message: "无法暂存下载文件，请检查磁盘空间后重试")
            )
            resumeNextTasks()
            return
        }

        let codec: String?
        let taskIdentifier: Int
        lock.lock()
        codec = codecs[id]
        tasks[id] = nil
        taskIdentifier = taskIdentifiers[id] ?? downloadTask.taskIdentifier
        infos[id]?.byteCount = downloadedBytes
        infos[id]?.progress = 1
        pendingCacheMoves += 1
        lock.unlock()
        resumeNextTasks()
        // store 是 actor，moveDownloadedFile 需要 await；delegate 回调是同步的，用 Task 包裹。
        // 组合键带 serverID：不同服务器同 trackID 的文件互不覆盖（P0-1）。
        let cacheID = TrackCacheStore.TrackCacheID(serverID: id.serverID, trackID: id.trackID)
        Task { [store, cacheID, codec, stagedLocation, self] in
            do {
                _ = try await store.moveDownloadedFile(at: stagedLocation, for: cacheID, codec: codec)
                let accepted = self.finishSuccess(id: id, taskIdentifier: taskIdentifier)
                if !accepted {
                    try? await store.remove(for: cacheID)
                }
            } catch {
                self.finishFailure(
                    id: id,
                    taskIdentifier: taskIdentifier,
                    failure: DownloadFailureInfo(kind: .storage, message: "无法保存到本地，请检查磁盘空间后重试")
                )
            }
            self.finishPendingCacheMove()
        }
    }

    /// 同步辅助：完成状态更新（从异步上下文调用，锁在同步方法内执行）。
    @discardableResult
    private func finishSuccess(id: DownloadTaskID, taskIdentifier: Int) -> Bool {
        lock.lock()
        let wasCancelled = cancelledTaskIdentifiers.remove(taskIdentifier) != nil
        var info = infos[id] ?? DownloadTaskInfo(trackID: id.trackID)
        info.status = wasCancelled ? .notDownloaded : .downloaded
        info.progress = wasCancelled ? 0 : 1
        info.failure = nil
        infos[id] = info
        codecs[id] = nil
        taskIdentifiers[id] = nil
        tasks[id] = nil
        recoveringTaskIdentifiers.remove(taskIdentifier)
        lock.unlock()
        metadataStore.remove(taskIdentifier: taskIdentifier)
        metadataStore.removeFailure(id: id)
        if !wasCancelled { notify(id) }
        return !wasCancelled
    }

    private func finishFailure(
        id: DownloadTaskID,
        taskIdentifier: Int,
        failure: DownloadFailureInfo
    ) {
        let codec: String?
        lock.lock()
        let wasCancelled = cancelledTaskIdentifiers.remove(taskIdentifier) != nil
        var info = infos[id] ?? DownloadTaskInfo(trackID: id.trackID)
        info.status = wasCancelled ? .notDownloaded : .failed
        info.failure = wasCancelled ? nil : failure
        infos[id] = info
        codec = codecs[id]
        codecs[id] = nil
        taskIdentifiers[id] = nil
        tasks[id] = nil
        recoveringTaskIdentifiers.remove(taskIdentifier)
        lock.unlock()
        metadataStore.remove(taskIdentifier: taskIdentifier)
        if wasCancelled {
            metadataStore.removeFailure(id: id)
        } else {
            metadataStore.saveFailure(id: id, info: info, codec: codec)
            notify(id)
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let id = taskID(for: task), error != nil else { return }
        lock.lock()
        let wasActive = tasks[id] != nil
        tasks[id] = nil
        let taskIdentifier = taskIdentifiers.removeValue(forKey: id) ?? task.taskIdentifier
        lock.unlock()
        guard wasActive else { return }
        finishFailure(
            id: id,
            taskIdentifier: taskIdentifier,
            failure: Self.failureInfo(for: error)
        )
        resumeNextTasks()
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
        let failures = metadataStore.failures()
        let persisted = metadataStore.all()
        lock.lock()
        for (id, info) in failures {
            infos[id] = info
        }
        for (taskIdentifier, metadata) in persisted {
            let id = DownloadTaskID(serverID: metadata.serverID, trackID: metadata.trackID)
            // 系统任务真实 state 要等 getAllTasks 返回；恢复期间先显示“排队中”，
            // 避免把尚未重连的任务误报为正在传输。
            infos[id] = DownloadTaskInfo(trackID: metadata.trackID, status: .queued)
            codecs[id] = metadata.codec
            taskIdentifiers[id] = taskIdentifier
        }
        lock.unlock()
    }

    /// App 可能在系统临时文件已交付、但尚未写进 TrackCacheStore 的极短窗口被终止。
    /// staging 文件名使用 URLSession taskIdentifier；业务身份仍从脱敏 metadata 恢复。
    private func recoverStagedDownloads() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: stagingDirectory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for file in files where file.pathExtension == "download" {
            guard
                let taskIdentifier = Int(file.deletingPathExtension().lastPathComponent),
                let metadata = metadataStore.metadata(for: taskIdentifier)
            else {
                try? FileManager.default.removeItem(at: file)
                continue
            }
            let id = DownloadTaskID(serverID: metadata.serverID, trackID: metadata.trackID)
            let byteCount = Self.fileSize(at: file)
            guard byteCount > 0 else {
                try? FileManager.default.removeItem(at: file)
                metadataStore.remove(taskIdentifier: taskIdentifier)
                continue
            }

            lock.lock()
            guard recoveringTaskIdentifiers.insert(taskIdentifier).inserted else {
                lock.unlock()
                continue
            }
            var info = infos[id] ?? DownloadTaskInfo(trackID: metadata.trackID)
            info.status = .downloading
            info.progress = 1
            info.byteCount = byteCount
            info.failure = nil
            infos[id] = info
            codecs[id] = metadata.codec
            taskIdentifiers[id] = taskIdentifier
            pendingCacheMoves += 1
            lock.unlock()
            notify(id)

            let cacheID = TrackCacheStore.TrackCacheID(serverID: id.serverID, trackID: id.trackID)
            Task { [store, cacheID, file, self] in
                do {
                    _ = try await store.moveDownloadedFile(at: file, for: cacheID, codec: metadata.codec)
                    let accepted = self.finishSuccess(id: id, taskIdentifier: taskIdentifier)
                    if !accepted { try? await store.remove(for: cacheID) }
                } catch {
                    self.finishFailure(
                        id: id,
                        taskIdentifier: taskIdentifier,
                        failure: DownloadFailureInfo(kind: .storage, message: "无法恢复已下载文件，请检查磁盘空间后重试")
                    )
                }
                self.finishPendingCacheMove()
            }
        }
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
        }

        // 只清理 getAllTasks 调用前已经存在的记录，避免与同时发生的新 start() 竞争。
        lock.lock()
        let recovering = recoveringTaskIdentifiers
        lock.unlock()
        let staleTaskIdentifiers = pruneCandidates
            .subtracting(activeTaskIdentifiers)
            .subtracting(recovering)
        var failedIDs: [DownloadTaskID] = []
        for taskIdentifier in staleTaskIdentifiers {
            guard let metadata = metadataStore.metadata(for: taskIdentifier) else { continue }
            metadataStore.remove(taskIdentifier: taskIdentifier)
            let id = DownloadTaskID(serverID: metadata.serverID, trackID: metadata.trackID)
            lock.lock()
            if taskIdentifiers[id] == taskIdentifier {
                taskIdentifiers[id] = nil
                codecs[id] = nil
                infos[id] = DownloadTaskInfo(
                    trackID: metadata.trackID,
                    status: .failed,
                    failure: DownloadFailureInfo(kind: .interrupted, message: "上次下载未完成，请重试")
                )
                if let info = infos[id] {
                    metadataStore.saveFailure(id: id, info: info, codec: metadata.codec)
                }
                failedIDs.append(id)
            }
            lock.unlock()
        }
        for id in failedIDs {
            notify(id)
        }
        resumeNextTasks()
    }

    private func bind(task: URLSessionDownloadTask, metadata: DownloadTaskMetadata) {
        let id = DownloadTaskID(serverID: metadata.serverID, trackID: metadata.trackID)
        lock.lock()
        // getAllTasks 可能先通过取消检查、随后用户才点取消。绑定时必须再次检查墓碑，
        // 否则迟到的恢复回调会把已取消任务重新放回 downloading。
        if cancelledTaskIdentifiers.remove(task.taskIdentifier) != nil {
            lock.unlock()
            task.taskDescription = nil
            metadataStore.remove(taskIdentifier: task.taskIdentifier)
            task.cancel()
            return
        }
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
        var info = infos[id] ?? DownloadTaskInfo(trackID: metadata.trackID)
        info.status = task.state == .running ? .downloading : .queued
        info.failure = nil
        infos[id] = info
        codecs[id] = metadata.codec
        lock.unlock()
        notify(id)
    }

    /// 只让固定数量的网络任务并发；其余任务保留为 URLSession suspended task，
    /// 因而仍可被后台会话恢复、取消和展示。批量离线不会再瞬间压满服务器与连接池。
    private func resumeNextTasks() {
        let candidates: [(DownloadTaskID, URLSessionDownloadTask)]
        lock.lock()
        let runningCount = tasks.values.filter { $0.state == .running }.count
        let availableSlots = max(maxConcurrentDownloads - runningCount, 0)
        candidates = tasks
            .filter { id, task in
                task.state == .suspended && infos[id]?.status == .queued
            }
            .sorted { $0.key.trackID.rawValue < $1.key.trackID.rawValue }
            .prefix(availableSlots)
            .map { ($0.key, $0.value) }
        for (id, _) in candidates {
            infos[id]?.status = .downloading
            infos[id]?.failure = nil
        }
        lock.unlock()

        for (id, task) in candidates {
            task.resume()
            notify(id)
        }
    }

    private func notify(_ id: DownloadTaskID) {
        lock.lock()
        let info = infos[id]
        lock.unlock()
        if let info { onStateChange(id, info) }
    }

    private static func fileSize(at url: URL) -> Int64 {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
    }

    private static func makeStagingDirectory() -> URL {
        let manager = FileManager.default
        let support = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? manager.temporaryDirectory
        let directory = support.appendingPathComponent("Auralis/DownloadStaging", isDirectory: true)
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableDirectory = directory
        try? mutableDirectory.setResourceValues(values)
        return directory
    }

    private func stageTemporaryDownload(at location: URL, taskIdentifier: Int) throws -> URL {
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        let destination = stagingDirectory.appendingPathComponent("\(taskIdentifier).download")
        if FileManager.default.fileExists(atPath: destination.path) {
            // 已由本进程恢复中的 staging 文件优先；系统重投递的临时副本交还系统清理。
            return destination
        }
        try FileManager.default.moveItem(at: location, to: destination)
        return destination
    }

    private static func responseFailure(for task: URLSessionDownloadTask) -> DownloadFailureInfo? {
        responseFailure(
            statusCode: (task.response as? HTTPURLResponse)?.statusCode,
            mimeType: task.response?.mimeType
        )
    }

    static func responseFailure(statusCode: Int?, mimeType: String?) -> DownloadFailureInfo? {
        if let statusCode {
            switch statusCode {
            case 200 ..< 300:
                break
            case 401, 403:
                return DownloadFailureInfo(kind: .authentication, message: "登录已失效，请重新连接服务器")
            case 404, 410:
                return DownloadFailureInfo(kind: .unavailable, message: "服务器上已找不到这首歌曲")
            case 500 ..< 600:
                return DownloadFailureInfo(kind: .unavailable, message: "音乐服务器暂时不可用，请稍后重试")
            default:
                return DownloadFailureInfo(kind: .invalidResponse, message: "下载请求失败（HTTP \(statusCode)）")
            }
        }

        let contentType = mimeType?.lowercased() ?? ""
        if contentType.contains("json") || contentType.contains("html") || contentType.contains("xml") {
            return DownloadFailureInfo(kind: .invalidResponse, message: "服务器返回的不是音频文件")
        }
        return nil
    }

    private static func failureInfo(for error: Error?) -> DownloadFailureInfo {
        guard let error else {
            return DownloadFailureInfo(kind: .unknown, message: "下载失败，请重试")
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            let code = URLError.Code(rawValue: nsError.code)
            switch code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost,
                 .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed:
                return DownloadFailureInfo(kind: .networkUnavailable, message: "网络不可用，联网后可重试")
            case .timedOut:
                return DownloadFailureInfo(kind: .timedOut, message: "下载超时，请重试")
            case .userAuthenticationRequired, .userCancelledAuthentication:
                return DownloadFailureInfo(kind: .authentication, message: "登录已失效，请重新连接服务器")
            default:
                break
            }
        }
        return DownloadFailureInfo(kind: .unknown, message: "下载中断，请重试")
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
