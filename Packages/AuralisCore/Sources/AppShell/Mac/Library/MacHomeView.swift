#if os(macOS)
import Domain
import LocalCatalog
import SwiftUI
import ThemeEngine

/// 首页：只展示真实有数据的货架（全部为网格卡片）。
/// 最近播放/最近添加按 Album 投影去重；收藏歌曲/播放列表等资料库入口由侧边栏负责。
struct MacHomeView: View {
    @ObservedObject var model: AuralisAppModel
    let theme: BuiltInTheme
    var onNavigate: (MacNavigationTarget) -> Void = { _ in }

    var body: some View {
        ScrollView {
            GeometryReader { geo in
                let homeMetrics = MacArtworkGridMetrics.home(availableWidth: geo.size.width)
                VStack(alignment: .leading, spacing: 26) {
                    albumShelf("最近播放专辑", albums: recentAlbums, seeAll: .recentlyPlayed, metrics: homeMetrics)
                    albumShelf("最近添加专辑", albums: recentAddedAlbums, seeAll: .recentlyAdded, metrics: homeMetrics)
                    albumShelf("常听专辑", albums: model.homeTopAlbums, seeAll: .albums, metrics: homeMetrics)
                    artistShelf("常听艺术家", artists: model.homeTopArtists, seeAll: .artists, metrics: homeMetrics)
                    trackShelf("很久没听", tracks: deduped(model.homeLongUnplayedTracks), metrics: homeMetrics)
                    trackShelf("从未播放", tracks: deduped(model.homeNeverPlayedTracks), metrics: homeMetrics)
                    trackShelf("收藏里随便听", tracks: deduped(model.homeFavoriteRandomTracks), metrics: homeMetrics)
                }
                .padding(.horizontal, homeMetrics.horizontalPadding)
                .padding(.top, 32)
                .padding(.bottom, 120)
            }
            .frame(minHeight: 700)
        }
    }

    /// 首页货架标题（有序）。资料库入口（歌曲/专辑/艺术家/流派/下载/不喜欢/播放列表/收藏）
    /// 由侧边栏负责，首页只保留“适合首页”的音乐内容卡片货架。供测试校验栏目切割。
    static let shelfTitles: [String] = [
        "最近播放专辑",
        "最近添加专辑",
        "常听专辑",
        "常听艺术家",
        "很久没听",
        "从未播放",
        "收藏里随便听",
    ]

    /// 首页不得包含这些（已由侧边栏资料库/播放列表区承担）。
    static let sidebarOnlyTitles: Set<String> = [
        "歌曲", "专辑", "艺术家", "流派", "下载", "不喜欢", "播放列表", "收藏",
    ]

    // MARK: - Album 投影（去重封面）

    private var recentAlbums: [Album] {
        albumProjection(from: model.homeRecentlyPlayedTracks)
    }

    private var recentAddedAlbums: [Album] {
        albumProjection(from: model.recentlyAddedTracks)
    }

    /// 曲目 → 按 (serverID, albumID) 去重 → 最新出现顺序的专辑。
    private func albumProjection(from tracks: [Track]) -> [Album] {
        var seen = Set<AlbumRouteIdentity>()
        var result: [Album] = []
        for track in tracks {
            let id = AlbumRouteIdentity(serverID: track.serverID, remoteID: track.albumID.rawValue)
            if seen.insert(id).inserted,
               let album = model.catalog.albums.first(where: { $0.serverID == track.serverID && $0.id == track.albumID }) {
                result.append(album)
                if result.count >= 14 { break }
            }
        }
        return result
    }

    /// 曲目货架去重（每专辑只保留第一首，避免同一封面反复出现）。
    private func deduped(_ tracks: [Track]) -> [Track] {
        var seen = Set<AlbumRouteIdentity>()
        var result: [Track] = []
        for track in tracks {
            let id = AlbumRouteIdentity(serverID: track.serverID, remoteID: track.albumID.rawValue)
            if seen.insert(id).inserted {
                result.append(track)
                if result.count >= 14 { break }
            }
        }
        return result
    }

    // MARK: - Shelves

    private func trackShelf(_ title: String, tracks: [Track], metrics: MacArtworkGridMetrics) -> some View {
        let items = Array(tracks.prefix(14))
        guard !items.isEmpty else { return AnyView(EmptyView()) }
        let size = min(150, metrics.itemWidth)
        return AnyView(
            VStack(alignment: .leading, spacing: 12) {
                MacSectionHeader(title: title)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 20) {
                        ForEach(items) { track in
                            MacTrackTile(
                                track: track,
                                model: model,
                                theme: theme,
                                size: size,
                                onOpen: { model.selectAndPlay(track) },
                                onPlay: { model.selectAndPlay(track) },
                                moreActions: trackMenuActions(track)
                            )
                        }
                    }
                    .padding(.horizontal, 2)
                }
            }
        )
    }

    private func albumShelf(_ title: String, albums: [Album], seeAll: MacSidebarDestination?, metrics: MacArtworkGridMetrics) -> some View {
        let items = Array(albums.prefix(14))
        guard !items.isEmpty else { return AnyView(EmptyView()) }
        let size = min(210, metrics.itemWidth)
        return AnyView(
            VStack(alignment: .leading, spacing: 12) {
                MacSectionHeader(title: title, actionTitle: seeAll == nil ? nil : "查看全部") {
                    if let seeAll { onNavigate(.sidebar(seeAll)) }
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 24) {
                        ForEach(items) { album in
                            MacAlbumTile(
                                album: album,
                                model: model,
                                theme: theme,
                                size: size,
                                onOpen: { onNavigate(.album(album)) },
                                onPlay: { model.playQueue(MacLibraryQuery.albumTracks(album, model: model)) },
                                moreActions: albumMoreActions(album)
                            )
                        }
                    }
                    .padding(.horizontal, 2)
                }
            }
        )
    }

    private func artistShelf(_ title: String, artists: [Artist], seeAll: MacSidebarDestination?, metrics: MacArtworkGridMetrics) -> some View {
        let items = Array(artists.prefix(14))
        guard !items.isEmpty else { return AnyView(EmptyView()) }
        let size = min(170, metrics.itemWidth)
        return AnyView(
            VStack(alignment: .leading, spacing: 12) {
                MacSectionHeader(title: title, actionTitle: seeAll == nil ? nil : "查看全部") {
                    if let seeAll { onNavigate(.sidebar(seeAll)) }
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 20) {
                        ForEach(items) { artist in
                            MacArtistTile(
                                artist: artist,
                                model: model,
                                theme: theme,
                                size: size,
                                onOpen: { onNavigate(.artist(artist)) },
                                onPlay: {
                                    let tracks = MacLibraryQuery.artistTracks(artist, model: model)
                                    if !tracks.isEmpty { model.playShuffledQueue(tracks) }
                                }
                            )
                        }
                    }
                    .padding(.horizontal, 2)
                }
            }
        )
    }

    private func trackMenuActions(_ track: Track) -> [MacMenuAction] {
        let gid = GlobalID(serverID: track.serverID, remoteID: track.id.rawValue)
        let isFavorite = track.isFavorite
        let isDisliked = model.isDisliked(track)
        let isDownloaded = model.isDownloaded(track)
        return [
            MacMenuAction(title: "下一首播放", systemImage: "text.badge.plus") { model.playNext(globalID: gid) },
            MacMenuAction(title: "加入队列", systemImage: "text.badge.plus") { model.addToQueue(globalID: gid) },
            MacMenuAction(title: isFavorite ? "取消收藏" : "收藏", systemImage: "heart") { model.toggleFavorite(track) },
            MacMenuAction(title: isDisliked ? "取消不喜欢" : "不喜欢", systemImage: "heart.slash") { model.setDisliked(track, value: !isDisliked, source: "user") },
            MacMenuAction(title: isDownloaded ? "删除下载" : "下载", systemImage: "arrow.down.circle") {
                if isDownloaded { model.removeDownload(track) } else { model.download(track) }
            },
            MacMenuAction(title: "歌曲信息", systemImage: "info.circle") {
                NotificationCenter.default.post(name: MacCommand.showTrackInformation, object: track)
            }
        ]
    }

    private func albumMoreActions(_ album: Album) -> [MacMenuAction] {
        let isFavorite = model.isAlbumFavorite(album)
        return [
            MacMenuAction(title: isFavorite ? "取消收藏专辑" : "收藏专辑", systemImage: "heart") { model.toggleAlbumFavorite(album) },
            MacMenuAction(title: "随机播放专辑", systemImage: "shuffle") { model.playShuffledQueue(MacLibraryQuery.albumTracks(album, model: model)) }
        ]
    }
}
#endif
