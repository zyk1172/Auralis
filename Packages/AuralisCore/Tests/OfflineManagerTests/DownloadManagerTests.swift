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
        let manager = DownloadManager(store: store)
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
        #expect(manager.status(idA)?.status == .downloading)
        #expect(manager.status(idB)?.status == .downloading)
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
        #expect(manager.status(metadata.trackID)?.status == .downloading)
        #expect(manager.activeSnapshots() == [
            ActiveDownloadSnapshot(
                serverID: metadata.serverID,
                info: DownloadTaskInfo(trackID: metadata.trackID, status: .downloading)
            ),
        ])

        manager.restoreForTesting(existingTasks: [], pruneCandidates: [42])

        #expect(!manager.isDownloading(metadata.trackID))
        #expect(manager.status(metadata.trackID)?.status == .failed)
        #expect(metadataStore.metadata(for: 42) == nil)
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
