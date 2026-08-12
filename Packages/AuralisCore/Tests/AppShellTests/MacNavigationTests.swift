@testable import AppShell
import Application
import Domain
import Foundation
import LocalCatalog
import Testing

/// Round-2 Apple Music Parity：导航拆分、搜索状态、队列语义、Genre 双键、Playlist mosaic。
@Suite("Mac navigation & parity corrections")
struct MacNavigationTests {
    // MARK: - Helpers

    @MainActor
    private func makeModel(tracks: [Track] = [], albums: [Album] = [], artists: [Artist] = [], genres: [Genre] = [], playlists: [Playlist] = []) -> AuralisAppModel {
        AuralisAppModel(
            catalog: LibraryCatalog(
                account: ServerAccount(
                    id: "server", displayName: "S",
                    baseURL: URL(string: "https://music.example.test")!,
                    username: "u", credentialReference: "c"
                ),
                artists: artists, albums: albums, tracks: tracks,
                genres: genres, playlists: playlists, history: [], downloads: [],
                lyrics: [:], recommendations: []
            ),
            connector: NoopConnector(),
            defaults: UserDefaults(suiteName: "mac-nav-\(UUID().uuidString)")!,
            storeURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("mac-nav-\(UUID().uuidString).sqlite")
        )
    }

    private func album(_ id: String, serverID: ServerID = "server") -> Album {
        Album(id: AlbumID(rawValue: id), serverID: serverID, artistID: ArtistID(rawValue: "artist"), title: id, artistName: "X")
    }

    private func track(_ id: String, serverID: ServerID = "server", albumID: String = "album", artwork: String? = nil) -> Track {
        Track(
            id: TrackID(rawValue: id), serverID: serverID,
            albumID: AlbumID(rawValue: albumID), artistID: ArtistID(rawValue: "artist"),
            title: id, artistName: "Artist", albumTitle: "Album",
            duration: 100, artworkKey: artwork
        )
    }

    // MARK: - 导航：查看全部 → 一级目的地

    @MainActor
    @Test("Home 查看全部专辑 → sidebar .albums 且清空 path")
    func homeSeeAllAlbums() {
        let nav = MacNavigationModel()
        nav.navigate(.sidebar(.albums))
        #expect(nav.selection == .albums)
        #expect(nav.path.isEmpty)
    }

    @MainActor
    @Test("Home 查看全部艺术家 → .artists")
    func homeSeeAllArtists() {
        let nav = MacNavigationModel()
        nav.navigate(.sidebar(.artists))
        #expect(nav.selection == .artists)
    }

    @MainActor
    @Test("Home 查看全部收藏 → .favorites")
    func homeSeeAllFavorites() {
        let nav = MacNavigationModel()
        nav.navigate(.sidebar(.favorites))
        #expect(nav.selection == .favorites)
    }

    @MainActor
    @Test("Search 浏览歌曲 → .songs")
    func searchBrowseSongs() {
        let nav = MacNavigationModel()
        nav.navigate(.sidebar(.songs))
        #expect(nav.selection == .songs)
    }

    @MainActor
    @Test("Search 浏览专辑 → .albums")
    func searchBrowseAlbums() {
        let nav = MacNavigationModel()
        nav.navigate(.sidebar(.albums))
        #expect(nav.selection == .albums)
    }

    // MARK: - 导航：详情 push

    @MainActor
    @Test("Search 专辑详情 → push detail，selection 不变")
    func searchDetailAlbumPushes() {
        let nav = MacNavigationModel()
        nav.selectSidebar(.songs)
        nav.navigate(.album(album("a1")))
        #expect(nav.path == [.album(MacEntityRouteID(serverID: "server", remoteID: "a1"))])
        #expect(nav.selection == .songs)
    }

    @MainActor
    @Test("detail push 不改变 sidebar selection")
    func detailPushKeepsSelection() {
        let nav = MacNavigationModel()
        nav.selectSidebar(.albums)
        nav.navigate(.detail(.artist(MacEntityRouteID(serverID: "server", remoteID: "ar1"))))
        #expect(nav.selection == .albums)
        #expect(nav.path.count == 1)
    }

    @MainActor
    @Test("path 存实体 ID 而非 snapshot；Catalog 变化后可重新解析")
    func pathStoresEntityID() {
        let nav = MacNavigationModel()
        let a = album("a1")
        nav.navigate(.album(a))
        guard case let .album(id) = nav.path[0] else {
            Issue.record("expected album route")
            return
        }
        #expect(id.serverID == a.serverID)
        #expect(id.remoteID == a.id.rawValue)
        // ID 可 Codable 往返（SceneStorage 持久化能力）。
        let data = try! JSONEncoder().encode(id)
        let decoded = try! JSONDecoder().decode(MacEntityRouteID.self, from: data)
        #expect(decoded == id)
    }

    // MARK: - 搜索状态

    @MainActor
    @Test("最近搜索点击设置真实 searchText 并打开搜索")
    func selectRecentSearchSetsQuery() {
        let nav = MacNavigationModel()
        nav.selectSidebar(.songs)
        nav.selectRecentSearch("王菲")
        #expect(nav.searchQuery == "王菲")
        #expect(nav.isSearchPresented)
        #expect(nav.selection == .songs)
    }

    @MainActor
    @Test("提交搜索记录历史")
    func submitRecordsHistory() {
        let model = makeModel()
        model.recordSearch("周杰伦")
        #expect(model.recentSearches.contains("周杰伦"))
    }

    @MainActor
    @Test("关闭搜索后恢复之前 Sidebar destination")
    func closingSearchRestoresDestination() {
        let nav = MacNavigationModel()
        nav.selectSidebar(.songs)
        nav.isSearchPresented = true
        #expect(nav.searchReturnDestination == .songs)
        nav.isSearchPresented = false
        #expect(nav.selection == .songs)
    }

    // MARK: - 队列语义

    @MainActor
    @Test("upcoming 排除当前曲目")
    func upcomingExcludesCurrent() {
        let model = makeModel(tracks: [track("a"), track("b"), track("c")])
        model.playQueue(model.catalog.tracks)
        #expect(model.upcomingTracks.map(\.id.rawValue) == ["b", "c"])
    }

    @MainActor
    @Test("clearUpcoming 保留当前曲目")
    func clearUpcomingKeepsCurrent() {
        let model = makeModel(tracks: [track("a"), track("b"), track("c")])
        model.playQueue(model.catalog.tracks)
        model.clearUpcoming()
        #expect(model.queue.map(\.id.rawValue) == ["a"])
        #expect(model.currentTrack.id.rawValue == "a")
    }

    @MainActor
    @Test("reorder upcoming 映射真实 queue 下标")
    func reorderUpcomingMapsRealIndex() {
        let model = makeModel(tracks: [track("a"), track("b"), track("c"), track("d")])
        model.playQueue(model.catalog.tracks)
        // 待播 [b,c,d]；把显示第 2 项 c 移到显示第 0 位 → 真实 [2] → to 1
        model.moveQueue(from: IndexSet([2]), to: 1)
        #expect(model.queue.map(\.id.rawValue) == ["a", "c", "b", "d"])
    }

    @MainActor
    @Test("delete upcoming 不删除当前曲目")
    func deleteUpcomingKeepsCurrent() {
        let model = makeModel(tracks: [track("a"), track("b"), track("c")])
        model.playQueue(model.catalog.tracks)
        // 待播显示 [b,c]；删除显示第 0 项 → 真实下标 1
        model.removeFromQueue(atOffsets: IndexSet([1]))
        #expect(model.queue.map(\.id.rawValue) == ["a", "c"])
        #expect(model.currentTrack.id.rawValue == "a")
    }

    // MARK: - Genre 双键

    @MainActor
    @Test("两服务器同 albumID 不串 Album")
    func genreAlbumDoubleKey() {
        let albumA = album("same", serverID: "s1")
        let albumB = album("same", serverID: "s2")
        let genre = Genre(name: "Rock", songCount: 2)
        // 只把 s1 的曲目归入 Rock 流派（带 genre 标签）
        let t1 = Track(
            id: TrackID(rawValue: "t1"), serverID: "s1",
            albumID: AlbumID(rawValue: "same"), artistID: ArtistID(rawValue: "artist"),
            title: "t1", artistName: "A", albumTitle: "Album", duration: 100,
            genres: ["Rock"]
        )
        let model = makeModel(tracks: [t1], albums: [albumA, albumB], genres: [genre])
        let albums = MacLibraryQuery.genreAlbums(genre, model: model)
        #expect(albums.count == 1)
        #expect(albums.first?.serverID == "s1")
    }

    // MARK: - Playlist mosaic

    @MainActor
    @Test("playlist mosaic 去重 artworkKey")
    func playlistMosaicDedupes() {
        let p = Playlist(id: "p1", serverID: "server", name: "Mix", trackIDs: [TrackID(rawValue: "t1"), TrackID(rawValue: "t2"), TrackID(rawValue: "t3"), TrackID(rawValue: "t4"), TrackID(rawValue: "t5")])
        let model = makeModel(tracks: [
            track("t1", albumID: "a1", artwork: "k1"),
            track("t2", albumID: "a2", artwork: "k1"),
            track("t3", albumID: "a3", artwork: "k2"),
            track("t4", albumID: "a4", artwork: "k3"),
            track("t5", albumID: "a5", artwork: "k4")
        ], playlists: [p])
        let keys = MacPlaylistArtwork.artworkKeys(playlist: p, model: model)
        #expect(keys == ["k1", "k2", "k3", "k4"])
        #expect(Set(keys).count == 4)
    }

    @MainActor
    @Test("空歌单 mosaic 返回空 key（占位）")
    func emptyPlaylistMosaic() {
        let p = Playlist(id: "p0", serverID: "server", name: "Empty", trackIDs: [])
        let model = makeModel(playlists: [p])
        #expect(MacPlaylistArtwork.artworkKeys(playlist: p, model: model).isEmpty)
    }

    // MARK: - GlobalID selection

    @Test("MacSongRow id 为 GlobalID（serverID+remoteID）")
    func songRowGlobalID() {
        let t = track("t1", serverID: "s9")
        let row = MacSongRow(id: GlobalID(serverID: t.serverID, remoteID: t.id.rawValue), track: t)
        #expect(row.id.serverID == "s9")
        #expect(row.id.remoteID == "t1")
    }

    private final class NoopConnector: ServerConnecting, @unchecked Sendable {
        func connect(_ input: ServerConnectionInput) async throws -> ServerConnectionResult {
            throw CancellationError()
        }
    }
}

@Suite("Mac sidebar library preferences")
struct MacSidebarPreferencesTests {
    @MainActor
    @Test("默认资料库项全部启用且顺序稳定")
    func defaultsAllEnabled() {
        let prefs = MacSidebarPreferences(defaults: UserDefaults(suiteName: "sb-\(UUID().uuidString)")!)
        let enabled = prefs.enabledDestinations
        #expect(enabled.contains(.songs))
        #expect(enabled.contains(.albums))
        #expect(enabled.first == .recentlyAdded)
    }

    @MainActor
    @Test("toggle 显示/隐藏并持久化往返")
    func togglePersists() {
        let defaults = UserDefaults(suiteName: "sb-persist-\(UUID().uuidString)")!
        let prefs = MacSidebarPreferences(defaults: defaults)
        prefs.toggle(MacSidebarDestination.albums.rawValue)
        #expect(!prefs.enabledDestinations.contains(.albums))

        // 新实例从同一 UserDefaults 恢复
        let restored = MacSidebarPreferences(defaults: defaults)
        #expect(!restored.enabledDestinations.contains(.albums))
        #expect(restored.enabledDestinations.contains(.songs))
    }

    @MainActor
    @Test("move 重新排序并持久化")
    func movePersists() {
        let defaults = UserDefaults(suiteName: "sb-move-\(UUID().uuidString)")!
        let prefs = MacSidebarPreferences(defaults: defaults)
        // 把「歌曲」移到最前
        let from = prefs.items.firstIndex { $0.id == MacSidebarDestination.songs.rawValue }!
        prefs.move(fromOffsets: IndexSet([from]), toOffset: 0)
        #expect(prefs.items.first?.id == MacSidebarDestination.songs.rawValue)

        let restored = MacSidebarPreferences(defaults: defaults)
        #expect(restored.items.first?.id == MacSidebarDestination.songs.rawValue)
    }
}
