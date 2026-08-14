import Domain
import Foundation
@testable import OfflineManager
import Testing

@Suite("下载管理与缓存落盘")
struct DownloadManagerTests {
    private func makeStore() -> TrackCacheStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return TrackCacheStore(directory: dir)
    }

    private func cacheID(_ server: String, _ track: String) -> TrackCacheStore.TrackCacheID {
        TrackCacheStore.TrackCacheID(serverID: ServerID(rawValue: server), trackID: TrackID(rawValue: track))
    }

    private func makeMetadataStore() -> (DownloadTaskMetadataStore, UserDefaults, String) {
        let suiteName = "DownloadManagerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        return (DownloadTaskMetadataStore(defaults: defaults), defaults, suiteName)
    }

    @Test("旧裸 TrackID 缓存迁移到最后活跃服务器且文件保留")
    func legacyIndexMigrationPreservesAudio() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let audioURL = directory.appendingPathComponent("legacy.flac")
        try Data("legacy-audio".utf8).write(to: audioURL)
        let indexData = try JSONEncoder().encode(["same-id": "legacy.flac"])
        try indexData.write(to: directory.appendingPathComponent("index.json"), options: .atomic)

        let store = TrackCacheStore(directory: directory)
        #expect((await store.cachedTrackIDs()).isEmpty)
        await store.migrateLegacyEntries(to: "old-server")

        let migrated = cacheID("old-server", "same-id")
        #expect(await store.isCached(migrated))
        let restoredURL = try #require(await store.cachedFileURL(for: migrated))
        #expect(try String(contentsOf: restoredURL, encoding: .utf8) == "legacy-audio")
    }

    @Test("moveDownloadedFile 把临时文件移入缓存并登记索引")
    func moveFileIntoCache() async throws {
        let store = makeStore()
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let source = tempDir.appendingPathComponent("tmp.flac")
        try Data("audio".utf8).write(to: source)

        let id = cacheID("srv-a", "t1")
        let moved = try await store.moveDownloadedFile(at: source, for: id, codec: "flac")
        #expect(moved.pathExtension == "flac")
        #expect(await store.cachedFileURL(for: id) != nil)
        #expect(await store.isCached(id))
    }

    @Test("路径字符规范化相同的 TrackID 不会覆盖彼此")
    func unsafeTrackIDsDoNotCollide() async throws {
        let store = makeStore()
        let first = cacheID("srv", "track/a")
        let second = cacheID("srv", "track?a")

        let firstURL = try await store.store(data: Data("first".utf8), for: first, codec: "flac")
        let secondURL = try await store.store(data: Data("second".utf8), for: second, codec: "flac")

        #expect(firstURL != secondURL)
        #expect(try String(contentsOf: #require(await store.cachedFileURL(for: first)), encoding: .utf8) == "first")
        #expect(try String(contentsOf: #require(await store.cachedFileURL(for: second)), encoding: .utf8) == "second")
    }

    @Test("同一歌曲重新下载新格式会删除旧文件并更新真实磁盘统计")
    func replacingDownloadRemovesOldFile() async throws {
        let store = makeStore()
        let id = cacheID("srv", "replace")
        let oldURL = try await store.store(data: Data("old".utf8), for: id, codec: "flac")
        let newURL = try await store.store(data: Data("new-audio".utf8), for: id, codec: "mp3")

        #expect(!FileManager.default.fileExists(atPath: oldURL.path))
        #expect(FileManager.default.fileExists(atPath: newURL.path))
        let entries = await store.cachedEntries()
        #expect(entries.count == 1)
        #expect(entries.first?.byteCount == 9)
        #expect(await store.totalBytes() == 9)
    }

    @Test("空文件拒绝入库且清空会同时清理索引与文件")
    func emptyFileRejectedAndRemoveAllClearsStore() async throws {
        let store = makeStore()
        let id = cacheID("srv", "valid")
        await #expect(throws: TrackCacheError.emptyFile) {
            _ = try await store.store(data: Data(), for: cacheID("srv", "empty"), codec: "flac")
        }
        let url = try await store.store(data: Data("valid".utf8), for: id, codec: "flac")

        try await store.removeAll()

        #expect((await store.cachedTrackIDs()).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(await store.totalBytes() == 0)
    }

    @Test("缓存文件被外部删除后索引条目立即清理，不残留元数据")
    func externallyDeletedFilePrunesIndexEntry() async throws {
        let store = makeStore()
        let id = cacheID("srv", "pruned")
        let url = try await store.store(data: Data("audio".utf8), for: id, codec: "flac")
        #expect(await store.isCached(id))

        try FileManager.default.removeItem(at: url)

        #expect(await store.cachedFileURL(for: id) == nil)
        #expect(!(await store.isCached(id)))
        #expect((await store.cachedTrackIDs()).isEmpty)
        #expect(await store.totalBytes() == 0)
    }

    @Test("同 trackID 不同 serverID 的两个文件并存且互不覆盖（P0-1 跨服务器隔离）")
    func sameTrackIDDifferentServersCoexist() async throws {
        let store = makeStore()
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let idA = cacheID("srv-a", "t9")
        let idB = cacheID("srv-b", "t9")
        let sourceA = tempDir.appendingPathComponent("a.flac")
        let sourceB = tempDir.appendingPathComponent("b.flac")
        try Data("AAA".utf8).write(to: sourceA)
        try Data("BBB".utf8).write(to: sourceB)

        _ = try await store.moveDownloadedFile(at: sourceA, for: idA, codec: "flac")
        _ = try await store.moveDownloadedFile(at: sourceB, for: idB, codec: "flac")

        #expect(await store.isCached(idA))
        #expect(await store.isCached(idB))
        let urlA = try #require(await store.cachedFileURL(for: idA))
        let urlB = try #require(await store.cachedFileURL(for: idB))
        #expect(urlA.path != urlB.path)
        #expect(try String(contentsOf: urlA, encoding: .utf8) == "AAA")
        #expect(try String(contentsOf: urlB, encoding: .utf8) == "BBB")
    }

    @Test("removeAll(forServer:) 只删除该服务器缓存，不影响其它服务器（P0-1）")
    func removeAllForServerKeepsOthers() async throws {
        let store = makeStore()
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let idA = cacheID("srv-a", "t1")
        let idB = cacheID("srv-b", "t1")
        let sourceA = tempDir.appendingPathComponent("a.flac")
        let sourceB = tempDir.appendingPathComponent("b.flac")
        try Data("AAA".utf8).write(to: sourceA)
        try Data("BBB".utf8).write(to: sourceB)
        _ = try await store.moveDownloadedFile(at: sourceA, for: idA, codec: "flac")
        _ = try await store.moveDownloadedFile(at: sourceB, for: idB, codec: "flac")

        await store.removeAll(forServer: ServerID(rawValue: "srv-a"))

        #expect(!(await store.isCached(idA)))
        #expect(await store.isCached(idB))
        #expect(await store.cachedTrackIDs().count == 1)
    }

    @Test("下载任务 start/cancel 状态正确")
    func startAndCancel() async {
        let store = makeStore()
        let (metadataStore, defaults, suiteName) = makeMetadataStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let manager = DownloadManager(
            store: store,
            metadataStore: metadataStore,
            automaticallyReconnect: false,
            stagingDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("DownloadManagerTests.staging.\(UUID().uuidString)"),
            sessionConfiguration: .ephemeral
        )
        let trackID = TrackID(rawValue: "t2")
        // 使用不会真的联网的本地地址；只验证状态机（下载会失败，但状态流转可验证）。
        let url = URL(string: "http://127.0.0.1:1/nonexistent.flac")!

        manager.start(trackID: trackID, url: url, codec: "flac", serverID: ServerID(rawValue: "srv-a"))
        #expect(manager.isDownloading(trackID))
        #expect(manager.status(trackID)?.status == .downloading)
        #expect(manager.activeCount() == 1)

        manager.cancel(trackID)
        #expect(!manager.isDownloading(trackID))
        #expect(manager.status(trackID)?.status == .notDownloaded)
        #expect(manager.activeCount() == 0)
    }

    @Test("后台任务身份可从 taskDescription 无损恢复")
    func taskDescriptionRoundTrip() {
        let metadata = DownloadTaskMetadata(
            trackID: TrackID(rawValue: "track/中文/42"),
            serverID: ServerID(rawValue: "server-a"),
            codec: "flac"
        )

        let description = metadata.taskDescription
        #expect(description != nil)
        #expect(DownloadTaskMetadata.decode(taskDescription: description) == metadata)
        #expect(DownloadTaskMetadata.decode(taskDescription: "unrelated") == nil)
    }

    @Test("裸 TrackID 兼容查询可重复调用且取消后立即返回 false")
    func legacyIsDownloadingLookupDoesNotDeadlock() {
        let (metadataStore, defaults, suiteName) = makeMetadataStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let metadata = DownloadTaskMetadata(trackID: "legacy-lookup", serverID: "server-a", codec: "flac")
        metadataStore.save(metadata, for: 17)
        let manager = DownloadManager(
            store: makeStore(),
            metadataStore: metadataStore,
            automaticallyReconnect: false
        )

        #expect(manager.isDownloading(metadata.trackID))
        #expect(manager.isDownloading(metadata.trackID))
        manager.cancel(DownloadTaskID(serverID: metadata.serverID, trackID: metadata.trackID))
        #expect(!manager.isDownloading(metadata.trackID))
    }

    @Test("相同 TrackID 在不同服务器的活动任务互不覆盖")
    func sameTrackIDAcrossServersHasIndependentRuntimeState() {
        let (metadataStore, defaults, suiteName) = makeMetadataStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let trackID = TrackID(rawValue: "shared-track")
        let metadataA = DownloadTaskMetadata(trackID: trackID, serverID: "server-a", codec: "flac")
        let metadataB = DownloadTaskMetadata(trackID: trackID, serverID: "server-b", codec: "alac")
        metadataStore.save(metadataA, for: 41)
        metadataStore.save(metadataB, for: 42)

        let manager = DownloadManager(
            store: makeStore(),
            metadataStore: metadataStore,
            automaticallyReconnect: false
        )
        let idA = DownloadTaskID(serverID: metadataA.serverID, trackID: trackID)
        let idB = DownloadTaskID(serverID: metadataB.serverID, trackID: trackID)

        #expect(manager.activeCount() == 2)
        #expect(manager.isDownloading(idA))
        #expect(manager.isDownloading(idB))
        #expect(manager.status(idA)?.status == .queued)
        #expect(manager.status(idB)?.status == .queued)
        #expect(manager.status(trackID) == nil) // 裸 ID 在多服务器场景必须保持不确定。

        manager.cancel(idA)
        #expect(!manager.isDownloading(idA))
        #expect(manager.isDownloading(idB))
        #expect(manager.activeCount() == 1)
        #expect(metadataStore.metadata(for: 41) == nil)
        #expect(metadataStore.metadata(for: 42) == metadataB)
    }

    @Test("持久映射会在新 DownloadManager 初始化时恢复并在系统任务缺失时标记失败")
    func persistedMetadataHydratesAndPrunesStaleTask() {
        let (metadataStore, defaults, suiteName) = makeMetadataStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let metadata = DownloadTaskMetadata(
            trackID: TrackID(rawValue: "restored-track"),
            serverID: ServerID(rawValue: "restored-server"),
            codec: "alac"
        )
        metadataStore.save(metadata, for: 42)

        let manager = DownloadManager(
            store: makeStore(),
            metadataStore: metadataStore,
            automaticallyReconnect: false
        )
        #expect(manager.isDownloading(metadata.trackID))
        #expect(manager.status(metadata.trackID)?.status == .queued)
        #expect(manager.activeSnapshots() == [
            ActiveDownloadSnapshot(
                serverID: metadata.serverID,
                info: DownloadTaskInfo(trackID: metadata.trackID, status: .queued)
            ),
        ])

        manager.restoreForTesting(existingTasks: [], pruneCandidates: [42])

        #expect(!manager.isDownloading(metadata.trackID))
        #expect(manager.status(metadata.trackID)?.status == .failed)
        #expect(metadataStore.metadata(for: 42) == nil)
    }

    @Test("中断失败会跨 DownloadManager 重建保留并可被用户重试")
    func failedStatePersistsAcrossManagerRecreation() {
        let (metadataStore, defaults, suiteName) = makeMetadataStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let metadata = DownloadTaskMetadata(trackID: "failed-track", serverID: "server-a", codec: "flac")
        metadataStore.save(metadata, for: 91)

        let first = DownloadManager(
            store: makeStore(),
            metadataStore: metadataStore,
            automaticallyReconnect: false
        )
        first.restoreForTesting(existingTasks: [], pruneCandidates: [91])

        let second = DownloadManager(
            store: makeStore(),
            metadataStore: metadataStore,
            automaticallyReconnect: false
        )
        let restored = second.stateSnapshots().first { $0.serverID == metadata.serverID }
        #expect(restored?.info.status == .failed)
        #expect(restored?.info.failure?.kind == .interrupted)
        #expect(restored?.info.failure?.message.isEmpty == false)
    }

    @Test("崩溃窗口中的 staging 临时文件会在下次启动恢复到正式缓存")
    func stagedDownloadRecoversOnNextLaunch() async throws {
        let (metadataStore, defaults, suiteName) = makeMetadataStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let cache = makeStore()
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("DownloadManagerTests.staging.\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let metadata = DownloadTaskMetadata(trackID: "recovered", serverID: "server-a", codec: "flac")
        metadataStore.save(metadata, for: 73)
        try Data("complete-audio".utf8).write(to: staging.appendingPathComponent("73.download"))

        let manager = DownloadManager(
            store: cache,
            metadataStore: metadataStore,
            automaticallyReconnect: false,
            stagingDirectory: staging
        )
        let id = cacheID("server-a", "recovered")
        for _ in 0 ..< 100 where !(await cache.isCached(id)) {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(await cache.isCached(id))
        #expect(metadataStore.metadata(for: 73) == nil)
        #expect(manager.status(DownloadTaskID(serverID: "server-a", trackID: "recovered"))?.status == .downloaded)
    }

    @Test("getAllTasks 恢复路径从任务描述重建 track/server/codec 映射")
    func restoresExistingURLSessionTask() {
        let (metadataStore, defaults, suiteName) = makeMetadataStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let metadata = DownloadTaskMetadata(
            trackID: TrackID(rawValue: "live-task"),
            serverID: ServerID(rawValue: "server-live"),
            codec: "opus"
        )
        let session = URLSession(configuration: .ephemeral)
        let task = session.downloadTask(with: URL(string: "http://127.0.0.1:1/audio")!)
        task.taskDescription = metadata.taskDescription

        let manager = DownloadManager(
            store: makeStore(),
            metadataStore: metadataStore,
            automaticallyReconnect: false
        )
        manager.restoreForTesting(existingTasks: [task])

        #expect(manager.isDownloading(metadata.trackID))
        #expect(manager.activeCount() == 1)
        #expect(manager.status(metadata.trackID)?.status == .downloading)
        #expect(metadataStore.metadata(for: task.taskIdentifier) == metadata)

        manager.cancel(metadata.trackID)
        session.invalidateAndCancel()
        #expect(metadataStore.metadata(for: task.taskIdentifier) == nil)
    }
}
