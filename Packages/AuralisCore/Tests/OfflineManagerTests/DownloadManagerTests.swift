import Domain
import Foundation
import OfflineManager
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
}
