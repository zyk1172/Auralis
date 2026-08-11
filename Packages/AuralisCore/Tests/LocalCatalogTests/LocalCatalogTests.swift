import Domain
import Foundation
import LocalCatalog
import MusicLibrary
import Testing

private func makeStore() throws -> LocalCatalogStore {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return try LocalCatalogStore(url: dir.appendingPathComponent("catalog.sqlite"))
}

private func makeTrack(serverID: ServerID, remoteID: String, title: String) -> Track {
    Track(
        id: TrackID(rawValue: remoteID),
        serverID: serverID,
        albumID: AlbumID(rawValue: "\(remoteID)-album"),
        artistID: ArtistID(rawValue: "\(remoteID)-artist"),
        title: title,
        artistName: "Artist \(serverID.rawValue)",
        albumTitle: "Album \(serverID.rawValue)",
        duration: 200
    )
}

private func seed(_ store: LocalCatalogStore, _ tracks: [Track]) async throws {
    guard let serverID = tracks.first?.serverID else { return }
    let session = try await store.beginSync(serverID: serverID, mode: .full)
    try await store.stageTracks(tracks, session: session)
    try await store.completeSync(session, completedAt: .now)
}

@Test("Multi-server: search is scoped per server")
func multiServerSearchIsolation() async throws {
    let store = try makeStore()
    try await seed(store, [makeTrack(serverID: "alpha", remoteID: "a1", title: "ZZAlphaSong")])
    try await seed(store, [makeTrack(serverID: "beta", remoteID: "b1", title: "ZZBetaSong")])

    let onlyAlpha = try await store.searchTracks(query: "ZZAlphaSong", serverID: "alpha")
    #expect(onlyAlpha.count == 1)
    #expect(onlyAlpha.first?.globalID.serverID == "alpha")

    let fromBeta = try await store.searchTracks(query: "ZZAlphaSong", serverID: "beta")
    #expect(fromBeta.isEmpty)

    let both = try await store.searchTracks(query: "ZZAlphaSong")
    #expect(both.count == 1)
}

@Test("Multi-server: playlists are scoped per server")
func multiServerPlaylistIsolation() async throws {
    let store = try makeStore()
    try await seed(store, [makeTrack(serverID: "alpha", remoteID: "a1", title: "ZZAlphaSong")])
    try await seed(store, [makeTrack(serverID: "beta", remoteID: "b1", title: "ZZBetaSong")])
    try await store.upsertPlaylist(Playlist(id: "pa", serverID: "alpha", name: "ZZAlphaPlaylist", trackIDs: []), serverID: "alpha", isReadOnly: false)
    try await store.upsertPlaylist(Playlist(id: "pb", serverID: "beta", name: "ZZBetaPlaylist", trackIDs: []), serverID: "beta", isReadOnly: false)

    let alphaPlaylists = try await store.listPlaylists(serverID: "alpha")
    #expect(alphaPlaylists.count == 1)
    #expect(alphaPlaylists.first?.name == "ZZAlphaPlaylist")

    let betaPlaylists = try await store.listPlaylists(serverID: "beta")
    #expect(betaPlaylists.count == 1)
    #expect(betaPlaylists.first?.name == "ZZBetaPlaylist")

    #expect(try await store.listPlaylists().count == 2)
}

/// Agent 的 listPlaylists 直接读 SQLite：歌单必须可写入、可读回（含曲目顺序）、可删除。
/// 此前歌单从未写入 SQLite，导致助手问「有多少个歌单」返回 0。
@Test("Playlist upsert/read-back/delete round trip matches Agent query path")
func playlistUpsertReadBackDeleteRoundTrip() async throws {
    let store = try makeStore()
    let serverID: ServerID = "alpha"
    try await seed(store, [
        makeTrack(serverID: serverID, remoteID: "t1", title: "Song 1"),
        makeTrack(serverID: serverID, remoteID: "t2", title: "Song 2"),
    ])

    // 写入 3 个歌单（含曲目顺序），模拟服务器同步。
    let p1 = Playlist(id: "pl1", serverID: serverID, name: "我的收藏", trackIDs: [TrackID(rawValue: "t2"), TrackID(rawValue: "t1")])
    let p2 = Playlist(id: "pl2", serverID: serverID, name: "通勤", trackIDs: [])
    let p3 = Playlist(id: "pl3", serverID: serverID, name: "深夜", trackIDs: [TrackID(rawValue: "t1")])
    try await store.upsertPlaylist(p1, serverID: serverID)
    try await store.upsertPlaylist(p2, serverID: serverID)
    try await store.upsertPlaylist(p3, serverID: serverID)

    // Agent 查询路径：listPlaylists 返回真实数量。
    let listed = try await store.listPlaylists(serverID: serverID)
    #expect(listed.count == 3)

    // getPlaylist 按顺序读回曲目。
    let detail = try await store.getPlaylist(GlobalID(serverID: serverID, remoteID: "pl1"))
    #expect(detail != nil)
    #expect(detail?.tracks.map(\.id.rawValue) == ["t2", "t1"])

    // 删除单个歌单后数量正确。
    try await store.deletePlaylist(GlobalID(serverID: serverID, remoteID: "pl2"))
    #expect(try await store.listPlaylists(serverID: serverID).count == 2)
    #expect(try await store.getPlaylist(GlobalID(serverID: serverID, remoteID: "pl2")) == nil)

    // 另一台服务器看不到这些歌单（多服务器隔离）。
    let other = try await store.listPlaylists(serverID: "beta")
    #expect(other.isEmpty)
}

@Test("Purge removes only the targeted server")
func purgeRemovesOnlyTargetedServer() async throws {
    let store = try makeStore()
    try await seed(store, [makeTrack(serverID: "alpha", remoteID: "a1", title: "ZZAlphaSong")])
    try await seed(store, [makeTrack(serverID: "beta", remoteID: "b1", title: "ZZBetaSong")])
    try await store.purgeServer("beta")

    #expect(try await store.allTrackSummaries(serverID: "beta").isEmpty)
    #expect(try await store.allTrackSummaries(serverID: "alpha").count == 1)
    #expect(try await store.searchTracks(query: "ZZBetaSong").isEmpty)
    #expect(try await store.searchTracks(query: "ZZAlphaSong").count == 1)
    #expect(try await store.listPlaylists(serverID: "beta").isEmpty)
}

@Test("Full sync stores all staged tracks and records completion")
func syncStoresStagedTracks() async throws {
    let store = try makeStore()
    let tracks = (1...5).map { makeTrack(serverID: "gamma", remoteID: "g\($0)", title: "Gamma \($0)") }
    try await seed(store, tracks)

    #expect(try await store.allTrackSummaries(serverID: "gamma").count == 5)
    let status = await store.syncStatus(for: "gamma")
    #expect(status.lastCompletedAt != nil)
}

@Test("Durable staging resumes after reopening and keeps the committed catalog visible")
func durableSyncStagingSurvivesRestart() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("auralis-durable-sync-(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("catalog.sqlite")
    let serverID: ServerID = "resume-server"

    let firstStore = try LocalCatalogStore(url: url)
    let committed = makeTrack(serverID: serverID, remoteID: "old", title: "Committed")
    let seedSession = try await firstStore.beginSync(serverID: serverID, mode: .full)
    try await firstStore.stageTracks([committed], session: seedSession)
    try await firstStore.completeSync(seedSession, completedAt: .now)

    let interrupted = try await firstStore.beginSync(serverID: serverID, mode: .full)
    let firstReplacement = makeTrack(serverID: serverID, remoteID: "new-1", title: "Replacement 1")
    try await firstStore.stageTracks([firstReplacement], session: interrupted)
    try await firstStore.saveCheckpoint(
        LibrarySyncCheckpoint(
            sessionID: interrupted.id,
            serverID: serverID,
            section: .tracks,
            continuation: "page-2",
            processedCount: 1
        ),
        session: interrupted
    )
    await firstStore.suspendSync(interrupted)

    // Staging is invisible: a terminated sync cannot expose a half-replaced catalog.
    #expect(try await firstStore.allTracks(serverID: serverID).map(\.id) == [committed.id])

    let reopened = try LocalCatalogStore(url: url)
    let resumed = try await reopened.beginSync(serverID: serverID, mode: .full)
    #expect(resumed.id == interrupted.id)
    let checkpoint = try await reopened.checkpoint(session: resumed, section: .tracks)
    #expect(checkpoint?.continuation == "page-2")
    #expect(checkpoint?.processedCount == 1)

    let secondReplacement = makeTrack(serverID: serverID, remoteID: "new-2", title: "Replacement 2")
    try await reopened.stageTracks([secondReplacement], session: resumed)
    try await reopened.saveCheckpoint(
        LibrarySyncCheckpoint(
            sessionID: resumed.id,
            serverID: serverID,
            section: .tracks,
            processedCount: 2,
            completedAt: .now
        ),
        session: resumed
    )
    try await reopened.completeSync(resumed, completedAt: .now)

    #expect(Set(try await reopened.allTracks(serverID: serverID).map(\.id)) == Set([firstReplacement.id, secondReplacement.id]))
    let freshSession = try await reopened.beginSync(serverID: serverID, mode: .full)
    #expect(freshSession.id != interrupted.id)
    await reopened.discardSync(freshSession)
}

@Test("Incremental staging is invisible until commit and merges atomically")
func incrementalStagingMergesOnlyAtCommit() async throws {
    let store = try makeStore()
    let serverID: ServerID = "incremental-server"
    let original = makeTrack(serverID: serverID, remoteID: "old", title: "Original")
    try await seed(store, [original])

    let session = try await store.beginSync(serverID: serverID, mode: .incremental)
    let added = makeTrack(serverID: serverID, remoteID: "new", title: "Added")
    try await store.stageTracks([added], session: session)
    #expect(try await store.allTracks(serverID: serverID).map(\.id) == [original.id])

    try await store.completeSync(session, completedAt: .now)
    #expect(Set(try await store.allTracks(serverID: serverID).map(\.id)) == Set([original.id, added.id]))
}

@Test("Recommendation Index V2 batches, validates, and reuses metadata classifications")
func recommendationIndexV2RoundTrip() async throws {
    let store = try makeStore()
    let serverID: ServerID = "v2"
    try await seed(store, [
        makeTrack(serverID: serverID, remoteID: "t1", title: "Night Piano"),
        makeTrack(serverID: serverID, remoteID: "t2", title: "Morning Run"),
    ])

    let initial = try await store.recommendationIndexV2Status(serverID: serverID)
    #expect(initial.totalTracks == 2)
    #expect(initial.pendingTracks == 2)

    let batch = try await store.nextRecommendationIndexV2Batch(serverID: serverID, limit: 80)
    #expect(batch.tracks.count == 2)
    let firstID = try #require(batch.tracks.first?.id)
    let secondID = try #require(batch.tracks.last?.id)
    let written = try await store.writeRecommendationIndexV2([
        .init(id: firstID, moods: ["平静"], scenes: ["深夜"], energy: 1, vocals: ["器乐"], textures: ["钢琴"], confidence: 0.92),
        .init(id: secondID, moods: ["明亮"], scenes: ["运动"], energy: 5, vocals: ["女声"], textures: ["电子"], confidence: 0.85),
        .init(id: "v2:not-a-track", moods: ["平静"], scenes: ["深夜"], energy: 1),
    ], serverID: serverID)
    #expect(written == 2)

    let complete = try await store.recommendationIndexV2Status(serverID: serverID)
    #expect(complete.indexedTracks == 2)
    #expect(complete.pendingTracks == 0)
    #expect(try await store.recommendationIndexV2TrackIDs(serverID: serverID, query: "深夜").map(\.description) == [firstID])
}

@Test("Multi-server: ratings are scoped per server and readable back")
func multiServerRatingIsolation() async throws {
    let store = try makeStore()
    try await seed(store, [makeTrack(serverID: "alpha", remoteID: "a1", title: "ZZAlphaSong")])
    try await seed(store, [makeTrack(serverID: "beta", remoteID: "b1", title: "ZZBetaSong")])

    try await store.setRating(GlobalID(serverID: "alpha", remoteID: "a1"), rating: 5)
    try await store.setRating(GlobalID(serverID: "beta", remoteID: "b1"), rating: 2)

    let alpha = try await store.ratings(serverID: "alpha")
    #expect(alpha[GlobalID(serverID: "alpha", remoteID: "a1")] == 5)
    #expect(alpha[GlobalID(serverID: "beta", remoteID: "b1")] == nil)

    let beta = try await store.ratings(serverID: "beta")
    #expect(beta[GlobalID(serverID: "beta", remoteID: "b1")] == 2)

    // 歌曲摘要应带上本地评分（Agent 的 library_get_song 读取该路径）
    let hits = try await store.searchTracks(query: "ZZAlphaSong", serverID: "alpha")
    #expect(hits.first?.userRating == 5)
}

@Test("allAlbums/allArtists read back staged records, scoped per server")
func allAlbumsAndArtistsRoundTrip() async throws {
    let store = try makeStore()
    let serverID: ServerID = "alpha"
    let artist = Artist(id: "ar-1", serverID: serverID, name: "Artist Alpha", albumCount: 1)
    let album = Album(
        id: "al-1", serverID: serverID, artistID: ArtistID(rawValue: "ar-1"),
        title: "Album One", artistName: "Artist Alpha", year: 2024
    )
    let track = makeTrack(serverID: serverID, remoteID: "t1", title: "Song 1")
    let session = try await store.beginSync(serverID: serverID, mode: .full)
    try await store.stageArtists([artist], session: session)
    try await store.stageAlbums([album], session: session)
    try await store.stageTracks([track], session: session)
    try await store.completeSync(session, completedAt: .now)

    let albums = try await store.allAlbums(serverID: serverID)
    #expect(albums.count == 1)
    #expect(albums.first?.id.rawValue == "al-1")
    #expect(albums.first?.title == "Album One")
    #expect(albums.first?.year == 2024)

    let artists = try await store.allArtists(serverID: serverID)
    #expect(artists.count == 1)
    #expect(artists.first?.id.rawValue == "ar-1")
    #expect(artists.first?.name == "Artist Alpha")

    // 多服务器隔离：另一台服务器读不到。
    #expect(try await store.allAlbums(serverID: "beta").isEmpty)
    #expect(try await store.allArtists(serverID: "beta").isEmpty)

    // 不带 serverID（nil）时返回全部。
    #expect(try await store.allAlbums(serverID: nil).count == 1)
    #expect(try await store.allArtists(serverID: nil).count == 1)
}
