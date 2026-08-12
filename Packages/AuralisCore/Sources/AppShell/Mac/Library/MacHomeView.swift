#if os(macOS)
import Domain
import LocalCatalog
import SwiftUI
import ThemeEngine

/// 首页：只展示真实有数据的货架。最近播放/最近添加按 Album 投影去重，
/// 收藏用紧凑歌曲列表，避免同一封面重复几十次。
struct MacHomeView: View {
    @ObservedObject var model: AuralisAppModel
    let theme: BuiltInTheme
    var onNavigate: (MacNavigationTarget) -> Void = { _ in }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                Text("首页")
                    .font(.system(size: MacLayout.pageTitleSize, weight: .bold, design: .default))
                    .accessibilityAddTraits(.isHeader)
                    .padding(.top, 4)

                albumShelf("最近播放专辑", albums: recentAlbums, seeAll: .recentlyPlayed)
                albumShelf("最近添加专辑", albums: recentAddedAlbums, seeAll: .recentlyAdded)
                favoriteList
                albumShelf("常听专辑", albums: model.homeTopAlbums, seeAll: .albums)
                artistShelf("常听艺术家", artists: model.homeTopArtists, seeAll: .artists)
                trackShelf("很久没听", tracks: deduped(model.homeLongUnplayedTracks))
                trackShelf("从未播放", tracks: deduped(model.homeNeverPlayedTracks))
                trackShelf("收藏里随便听", tracks: deduped(model.homeFavoriteRandomTracks))
                playlistShelf("播放列表", seeAll: .playlists)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 28)
        }
    }

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

    private func trackShelf(_ title: String, tracks: [Track]) -> some View {
        let items = Array(tracks.prefix(14))
        guard !items.isEmpty else { return AnyView(EmptyView()) }
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

    private func albumShelf(_ title: String, albums: [Album], seeAll: MacSidebarDestination?) -> some View {
        let items = Array(albums.prefix(14))
        guard !items.isEmpty else { return AnyView(EmptyView()) }
        return AnyView(
            VStack(alignment: .leading, spacing: 12) {
                MacSectionHeader(title: title, actionTitle: seeAll == nil ? nil : "查看全部") {
                    if let seeAll { onNavigate(.sidebar(seeAll)) }
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 20) {
                        ForEach(items) { album in
                            MacAlbumTile(
                                album: album,
                                model: model,
                                theme: theme,
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

    private func artistShelf(_ title: String, artists: [Artist], seeAll: MacSidebarDestination?) -> some View {
        let items = Array(artists.prefix(14))
        guard !items.isEmpty else { return AnyView(EmptyView()) }
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

    private func playlistShelf(_ title: String, seeAll: MacSidebarDestination?) -> some View {
        let playlists = model.catalog.playlists.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        guard !playlists.isEmpty else { return AnyView(EmptyView()) }
        return AnyView(
            VStack(alignment: .leading, spacing: 12) {
                MacSectionHeader(title: title, actionTitle: seeAll == nil ? nil : "查看全部") {
                    if let seeAll { onNavigate(.sidebar(seeAll)) }
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 20) {
                        ForEach(playlists.prefix(14)) { playlist in
                            MacPlaylistTile(
                                playlist: playlist,
                                model: model,
                                theme: theme,
                                onOpen: { onNavigate(.playlist(playlist)) },
                                onPlay: {
                                    let tracks = MacLibraryQuery.playlistTracks(playlist, model: model)
                                    if !tracks.isEmpty { model.playQueue(tracks) }
                                }
                            )
                        }
                    }
                    .padding(.horizontal, 2)
                }
            }
        )
    }

    /// 收藏：紧凑歌曲列表，不强制等大封面卡。
    private var favoriteList: some View {
        let favorites = Array(model.homeFavoriteTracks.prefix(8))
        guard !favorites.isEmpty else { return AnyView(EmptyView()) }
        return AnyView(
            VStack(alignment: .leading, spacing: 10) {
                MacSectionHeader(title: "收藏", actionTitle: "查看全部") {
                    onNavigate(.sidebar(.favorites))
                }
                VStack(spacing: 0) {
                    ForEach(Array(favorites.enumerated()), id: \.element.id) { index, track in
                        HStack(spacing: 10) {
                            ArtworkView(title: track.albumTitle, artworkKey: track.artworkKey, colors: theme.colorTokens, size: 32, cornerRadius: 4)
                                .accessibilityHidden(true)
                            Button {
                                model.selectAndPlay(track)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(track.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                        Text(track.artistName).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer()
                                    Text(MacFormat.time(track.duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .macTrackContextMenu(track: track, model: model, onNavigate: onNavigate)
                        }
                        if index < favorites.count - 1 { Divider().padding(.leading, 42) }
                    }
                }
                .padding(.trailing, 12)
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
