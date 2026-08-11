@testable import AppShell
import Domain
import Foundation
import LocalCatalog
import Testing

@Test("首次入库时间按服务器隔离并仅清理当前服务器失效歌曲")
func libraryAddedTrackerUsesGlobalIDs() {
    let firstServer = ServerID(rawValue: "first")
    let secondServer = ServerID(rawValue: "second")
    let initial = Date(timeIntervalSince1970: 100)
    let later = Date(timeIntervalSince1970: 200)
    var tracker = LibraryAddedTracker(
        stored: [
            "first:same": initial.timeIntervalSince1970,
            "second:same": initial.timeIntervalSince1970,
            "first:removed": initial.timeIntervalSince1970,
        ],
        legacyServerID: nil
    )

    let same = testTrack(id: "same", serverID: firstServer)
    let added = testTrack(id: "new", serverID: firstServer)
    let didReconcile = tracker.reconcile(tracks: [same, added], serverID: firstServer, now: later)
    #expect(didReconcile)
    #expect(tracker.dates[GlobalID(serverID: firstServer, remoteID: "same")] == initial)
    #expect(tracker.dates[GlobalID(serverID: firstServer, remoteID: "new")] == later)
    #expect(tracker.dates[GlobalID(serverID: firstServer, remoteID: "removed")] == nil)
    #expect(tracker.dates[GlobalID(serverID: secondServer, remoteID: "same")] == initial)
}

@Test("旧裸 TrackID 使用最后活动服务器迁移为 GlobalID")
func libraryAddedTrackerMigratesLegacyKeys() {
    let serverID = ServerID(rawValue: "legacy-server")
    let tracker = LibraryAddedTracker(stored: ["song": 123], legacyServerID: serverID)
    #expect(tracker.dates[GlobalID(serverID: serverID, remoteID: "song")] == Date(timeIntervalSince1970: 123))
    #expect(tracker.encoded["legacy-server:song"] == 123)
}

@Test("启动时尚未选择服务器的旧裸 TrackID 会延迟到首次同步再迁移")
func libraryAddedTrackerDefersLegacyMigrationUntilServerIsKnown() {
    let serverID = ServerID(rawValue: "later-server")
    let track = testTrack(id: "song", serverID: serverID)
    var tracker = LibraryAddedTracker(stored: ["song": 123], legacyServerID: nil)

    #expect(tracker.encoded["song"] == 123)
    let didReconcile = tracker.reconcile(
        tracks: [track],
        serverID: serverID,
        now: Date(timeIntervalSince1970: 999)
    )
    #expect(didReconcile)
    #expect(tracker.date(for: track) == Date(timeIntervalSince1970: 123))
    #expect(tracker.encoded["song"] == nil)
    #expect(tracker.encoded["later-server:song"] == 123)
}

private func testTrack(id: String, serverID: ServerID) -> Track {
    Track(
        id: TrackID(rawValue: id),
        serverID: serverID,
        albumID: AlbumID(rawValue: "album"),
        artistID: ArtistID(rawValue: "artist"),
        title: id,
        artistName: "Artist",
        albumTitle: "Album",
        duration: 180
    )
}
