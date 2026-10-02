// SPDX-License-Identifier: GPL-3.0-only
import Domain
import Foundation
@testable import OfflineManager
import Testing

private final class PendingDownloadProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {}
    override func stopLoading() {}
}

@Suite("Download attempt ownership")
struct DownloadAttemptOwnershipTests {
    @Test("Old terminal callbacks leave a cancelled-and-retried task intact")
    func staleTerminalCallbacks() throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PendingDownloadProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let defaults = UserDefaults(suiteName: "download-ownership-\(UUID().uuidString)")!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = TrackCacheStore(directory: root)
        let manager = DownloadManager(store: store, metadataStore: DownloadTaskMetadataStore(defaults: defaults),
                                      automaticallyReconnect: false, stagingDirectory: root.appendingPathComponent("staging"),
                                      sessionConfiguration: configuration)
        let metadata = DownloadTaskMetadata(trackID: "track", serverID: "server", codec: "flac")
        let id = DownloadTaskID(serverID: "server", trackID: "track")
        let first = session.downloadTask(with: URL(string: "https://music.example.test/first")!)
        first.taskDescription = metadata.taskDescription
        manager.restoreForTesting(existingTasks: [first])
        manager.cancel(id)
        let second = session.downloadTask(with: URL(string: "https://music.example.test/second")!)
        second.taskDescription = metadata.taskDescription
        manager.restoreForTesting(existingTasks: [second])

        #expect(!manager.finishSuccess(id: id, taskIdentifier: first.taskIdentifier))
        manager.finishFailure(id: id, taskIdentifier: first.taskIdentifier,
                              failure: DownloadFailureInfo(kind: .storage, message: "old failure"))
        #expect(manager.activeSnapshots().count == 1)
        #expect(manager.status(id)?.status == .downloading)
        #expect(manager.finishSuccess(id: id, taskIdentifier: second.taskIdentifier))
        #expect(manager.status(id)?.status == .downloaded)
        #expect(manager.activeSnapshots().isEmpty)
    }

    @Test("Rejected file cleanup cannot delete a newer installation")
    func conditionalCleanup() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = TrackCacheStore(directory: root)
        let id = TrackCacheStore.TrackCacheID(serverID: "server", trackID: "track")
        let first = try await store.store(data: Data("first".utf8), for: id, codec: "flac")
        let second = try await store.store(data: Data("second".utf8), for: id, codec: "flac")
        try await store.remove(for: id, ifMatching: first)
        #expect(await store.cachedFileURL(for: id) == second)
        #expect(try Data(contentsOf: second) == Data("second".utf8))
    }

    @Test("An obsolete attempt cannot install over an existing cached file")
    func obsoleteInstallation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = TrackCacheStore(directory: root)
        let id = TrackCacheStore.TrackCacheID(serverID: "server", trackID: "track")
        let current = try await store.store(data: Data("current".utf8), for: id, codec: "flac")
        let staged = root.appendingPathComponent("obsolete.download")
        try Data("obsolete".utf8).write(to: staged)
        await #expect(throws: CancellationError.self) {
            _ = try await store.moveDownloadedFile(at: staged, for: id, codec: "flac", shouldInstall: { false })
        }
        #expect(await store.cachedFileURL(for: id) == current)
        #expect(!FileManager.default.fileExists(atPath: staged.path))
    }
}
