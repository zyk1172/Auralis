@testable import AppShell
import Domain
import Foundation
import LocalCatalog
import Testing

/// Mac「艺术家」崩溃点回归（RC issue 6）。
/// 覆盖：LibraryStore 派生索引（GlobalID 去重/合并/跨服务器隔离/大目录完整性）、
/// 目录刷新时索引重建，以及 MacArtistView 缓存契约（GlobalID 查询 + 常听 Top 12 纯函数）。
/// 全部为纯逻辑测试：不依赖模拟器、不联网、不启动播放引擎。
@Suite("Mac Artists crash regression")
struct MacArtistsRegressionTests {
    // MARK: - 构造

    private func makeCatalog(artists: [Artist], albums: [Album], tracks: [Track]) -> LibraryCatalog {
        LibraryCatalog(
            account: ServerAccount(id: "test", displayName: "Test"),
            artists: artists,
            albums: albums,
            tracks: tracks,
            genres: [],
            playlists: [],
            history: [],
            downloads: [],
            lyrics: [:],
            recommendations: []
        )
    }

    private func artist(_ id: String, serverID: ServerID = "srv", albumCount: Int = 0) -> Artist {
        Artist(id: ArtistID(rawValue: id), serverID: serverID, name: "Artist \(id)", albumCount: albumCount)
    }

    private func album(_ id: String, artistID: String, serverID: ServerID = "srv", year: Int? = nil) -> Album {
        Album(
            id: AlbumID(rawValue: id), serverID: serverID,
            artistID: ArtistID(rawValue: artistID),
            title: "Album \(id)", artistName: "Artist \(artistID)", year: year
        )
    }

    private func track(_ id: String, artistID: String, albumID: String, serverID: ServerID = "srv") -> Track {
        Track(
            id: TrackID(rawValue: id), serverID: serverID,
            albumID: AlbumID(rawValue: albumID), artistID: ArtistID(rawValue: artistID),
            title: "Track \(id)", artistName: "Artist \(artistID)", albumTitle: "Album \(albumID)",
            duration: 100
        )
    }

    // MARK: - 空目录 / 单艺术家

    @MainActor
    @Test("0 艺术家：三张派生索引为空，GlobalID 查找安全返回空数组")
    func emptyCatalogProducesEmptyIndexes() {
        let store = LibraryStore(catalog: .empty)
        #expect(store.trackByGlobalID.isEmpty)
        #expect(store.tracksByArtist.isEmpty)
        #expect(store.albumsByArtist.isEmpty)
        #expect(store.tracksByAlbum.isEmpty)

        let gid = GlobalID(serverID: "srv", remoteID: "missing")
        #expect(store.tracks(artistGlobalID: gid).isEmpty)
        #expect(store.albums(artistGlobalID: gid).isEmpty)
        #expect(store.tracks(albumGlobalID: gid).isEmpty)
        #expect(store.track(for: gid) == nil)
    }

    @MainActor
    @Test("1 艺术家：按艺术家/专辑 GlobalID 命中正确曲目与专辑，既有 track(for:) 仍可用")
    func singleArtistIndexResolves() {
        let catalog = makeCatalog(
            artists: [artist("a1")],
            albums: [album("al1", artistID: "a1"), album("al2", artistID: "a1")],
            tracks: [
                track("t1", artistID: "a1", albumID: "al1"),
                track("t2", artistID: "a1", albumID: "al1"),
                track("t3", artistID: "a1", albumID: "al2"),
            ]
        )
        let store = LibraryStore(catalog: catalog)
        let artistGID = GlobalID(serverID: "srv", remoteID: "a1")

        #expect(store.tracks(artistGlobalID: artistGID).map(\.id.rawValue) == ["t1", "t2", "t3"])
        #expect(store.albums(artistGlobalID: artistGID).map(\.id.rawValue) == ["al1", "al2"])
        #expect(store.tracks(albumGlobalID: GlobalID(serverID: "srv", remoteID: "al1")).map(\.id.rawValue) == ["t1", "t2"])

        // 实体便捷方法结果一致
        #expect(store.tracks(artist: catalog.artists[0]).map(\.id.rawValue) == ["t1", "t2", "t3"])
        #expect(store.albums(artist: catalog.artists[0]).map(\.id.rawValue) == ["al1", "al2"])
        #expect(store.tracks(album: catalog.albums[0]).map(\.id.rawValue) == ["t1", "t2"])
        #expect(store.track(for: GlobalID(serverID: "srv", remoteID: "t3"))?.id == TrackID(rawValue: "t3"))
    }

    // MARK: - 大规模目录

    @MainActor
    @Test("5000 艺术家：索引桶完整，首尾查找不丢桶")
    func fiveThousandArtistsIndexComplete() {
        let artists = (0..<5000).map { artist("a\($0)") }
        let albums = (0..<5000).map { album("al\($0)", artistID: "a\($0)") }
        let tracks = (0..<5000).map { track("t\($0)", artistID: "a\($0)", albumID: "al\($0)") }
        let store = LibraryStore(catalog: makeCatalog(artists: artists, albums: albums, tracks: tracks))

        #expect(store.tracksByArtist.count == 5000)
        #expect(store.albumsByArtist.count == 5000)
        #expect(store.tracksByAlbum.count == 5000)
        #expect(store.tracks(artistGlobalID: GlobalID(serverID: "srv", remoteID: "a0")).map(\.id.rawValue) == ["t0"])
        #expect(store.tracks(artistGlobalID: GlobalID(serverID: "srv", remoteID: "a4999")).map(\.id.rawValue) == ["t4999"])
        #expect(store.albums(artistGlobalID: GlobalID(serverID: "srv", remoteID: "a0")).map(\.id.rawValue) == ["al0"])
        #expect(store.tracks(albumGlobalID: GlobalID(serverID: "srv", remoteID: "al2500")).map(\.id.rawValue) == ["t2500"])
    }

    @MainActor
    @Test("25000 曲目：艺术家/专辑索引聚合正确，桶内总和 == 曲目总数")
    func twentyFiveThousandTracksIndexComplete() {
        let artists = (0..<1000).map { artist("a\($0)") }
        let albums = (0..<2500).map { album("al\($0)", artistID: "a\($0 % 1000)") }
        let tracks = (0..<25000).map { track("t\($0)", artistID: "a\($0 % 1000)", albumID: "al\($0 % 2500)") }
        let store = LibraryStore(catalog: makeCatalog(artists: artists, albums: albums, tracks: tracks))

        #expect(store.tracksByArtist.count == 1000)
        #expect(store.albumsByArtist.count == 1000)
        #expect(store.tracksByAlbum.count == 2500)
        #expect(store.tracks(artistGlobalID: GlobalID(serverID: "srv", remoteID: "a0")).count == 25)
        #expect(store.tracks(albumGlobalID: GlobalID(serverID: "srv", remoteID: "al0")).count == 10)

        let totalIndexed = store.tracksByArtist.values.reduce(0) { $0 + $1.count }
        #expect(totalIndexed == 25000)
    }

    // MARK: - 身份去重 / 合并 / 隔离

    @MainActor
    @Test("重复 remote ArtistID（同服务器）：按 GlobalID 合并去重，避免 ForEach 重复身份")
    func duplicateRemoteArtistIDMergesByGlobalID() {
        // 目录里同一 (serverID, remoteID) 的艺术家/专辑/曲目各出现两次。
        let store = LibraryStore(catalog: makeCatalog(
            artists: [artist("a1"), artist("a1")],
            albums: [album("al1", artistID: "a1"), album("al1", artistID: "a1")],
            tracks: [track("t1", artistID: "a1", albumID: "al1"), track("t1", artistID: "a1", albumID: "al1")]
        ))
        let artistGID = GlobalID(serverID: "srv", remoteID: "a1")
        #expect(store.tracksByArtist[artistGID]?.count == 1)
        #expect(store.albumsByArtist[artistGID]?.count == 1)
        #expect(store.tracksByAlbum[GlobalID(serverID: "srv", remoteID: "al1")]?.count == 1)
        #expect(store.trackByGlobalID[GlobalID(serverID: "srv", remoteID: "t1")] != nil)
    }

    @MainActor
    @Test("跨服务器同 remote ArtistID：GlobalID 隔离，互不串库")
    func crossServerSameRemoteArtistIDIsolated() {
        let s1: ServerID = "s1"
        let s2: ServerID = "s2"
        let store = LibraryStore(catalog: makeCatalog(
            artists: [artist("a1", serverID: s1), artist("a1", serverID: s2)],
            albums: [
                album("al1", artistID: "a1", serverID: s1),
                album("al1", artistID: "a1", serverID: s2),
            ],
            tracks: [
                track("t1", artistID: "a1", albumID: "al1", serverID: s1),
                track("t1", artistID: "a1", albumID: "al1", serverID: s2),
            ]
        ))
        let gid1 = GlobalID(serverID: s1, remoteID: "a1")
        let gid2 = GlobalID(serverID: s2, remoteID: "a1")
        #expect(gid1 != gid2)
        #expect(store.tracksByArtist.count == 2)
        #expect(store.albumsByArtist.count == 2)
        #expect(store.tracks(artistGlobalID: gid1).map(\.serverID) == [s1])
        #expect(store.tracks(artistGlobalID: gid2).map(\.serverID) == [s2])
        #expect(store.albums(artistGlobalID: gid1).map(\.serverID) == [s1])
        #expect(store.tracks(albumGlobalID: GlobalID(serverID: s1, remoteID: "al1")).map(\.serverID) == [s1])
        #expect(store.tracks(albumGlobalID: GlobalID(serverID: s2, remoteID: "al1")).map(\.serverID) == [s2])
    }

    // MARK: - 边界：0 专辑 / 数千曲目

    @MainActor
    @Test("0 专辑艺术家：专辑桶为空、曲目桶正确")
    func artistWithZeroAlbums() {
        let store = LibraryStore(catalog: makeCatalog(
            artists: [artist("a1")],
            albums: [],
            tracks: [track("t1", artistID: "a1", albumID: "al-missing")]
        ))
        let artistGID = GlobalID(serverID: "srv", remoteID: "a1")
        #expect(store.albums(artistGlobalID: artistGID).isEmpty)
        #expect(store.tracks(artistGlobalID: artistGID).map(\.id.rawValue) == ["t1"])
        #expect(store.tracks(albumGlobalID: GlobalID(serverID: "srv", remoteID: "al-missing")).map(\.id.rawValue) == ["t1"])
    }

    @MainActor
    @Test("数千曲目艺术家：索引完整且常听 Top 12 稳定")
    func artistWithThousandsOfTracks() {
        let tracks = (0..<5000).map { track("t\($0)", artistID: "a1", albumID: "al\($0 % 50)") }
        let store = LibraryStore(catalog: makeCatalog(
            artists: [artist("a1", albumCount: 50)],
            albums: (0..<50).map { album("al\($0)", artistID: "a1") },
            tracks: tracks
        ))
        let artistGID = GlobalID(serverID: "srv", remoteID: "a1")
        #expect(store.tracks(artistGlobalID: artistGID).count == 5000)
        #expect(store.albums(artistGlobalID: artistGID).count == 50)
        #expect(store.tracksByArtist[artistGID]?.count == 5000)

        #if os(macOS)
        // MacArtistView 缓存契约：Top 12 只含播放过、按次数降序、最多 12 首。
        var playCounts: [TrackID: Int] = [:]
        for i in 0..<5000 where i % 2 == 0 {
            playCounts[TrackID(rawValue: "t\(i)")] = i % 100
        }
        let top = MacArtistView.topPlayedTracks(tracks, playCounts: playCounts)
        #expect(top.count == 12)
        #expect(top.allSatisfy { (playCounts[$0.id] ?? 0) > 0 })
        let counts = top.map { playCounts[$0.id] ?? 0 }
        #expect(counts == counts.sorted(by: >))
        #expect(playCounts[TrackID(rawValue: "t1")] == nil)
        #expect(!top.contains { $0.id.rawValue == "t1" })
        #endif
    }

    // MARK: - 目录刷新（Artists 页打开时）

    @MainActor
    @Test("目录刷新（Artists 页打开）：索引整体重建并按 GlobalID 去重合并")
    func catalogRefreshRebuildsIndexes() {
        let store = LibraryStore(catalog: makeCatalog(
            artists: [artist("a1")],
            albums: [album("al1", artistID: "a1")],
            tracks: [track("t1", artistID: "a1", albumID: "al1")]
        ))
        let a1GID = GlobalID(serverID: "srv", remoteID: "a1")
        #expect(store.tracks(artistGlobalID: a1GID).map(\.id.rawValue) == ["t1"])

        // 模拟同步刷新：新目录（新艺术家 + 与旧目录重叠的重复条目）。
        store.catalog = makeCatalog(
            artists: [artist("a1"), artist("a1"), artist("a2")],
            albums: [
                album("al1", artistID: "a1"),
                album("al1", artistID: "a1"),
                album("al2", artistID: "a2"),
            ],
            tracks: [
                track("t1", artistID: "a1", albumID: "al1"),
                track("t1", artistID: "a1", albumID: "al1"), // 重复 GlobalID → 合并
                track("t2", artistID: "a2", albumID: "al2"),
            ]
        )
        // 索引已重建：a1 桶仍是去重后的 t1；a2 桶出现；无旧残留。
        #expect(store.tracks(artistGlobalID: a1GID).map(\.id.rawValue) == ["t1"])
        #expect(store.albums(artistGlobalID: a1GID).map(\.id.rawValue) == ["al1"])
        #expect(store.tracks(artistGlobalID: GlobalID(serverID: "srv", remoteID: "a2")).map(\.id.rawValue) == ["t2"])
        #expect(store.albumsByArtist.count == 2)
        #expect(store.tracksByArtist[a1GID]?.count == 1) // 去重
    }
}
