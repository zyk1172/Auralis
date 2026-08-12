#if os(macOS)
import Domain
import SwiftUI
import ThemeEngine
import LocalCatalog

/// Apple Music 式首页：只有真实有数据的货架，无 server card / 继续播放大卡片。
struct MacHomeView: View {
    @ObservedObject var model: AuralisAppModel
    let theme: BuiltInTheme
    var onNavigate: (MacRoute) -> Void = { _ in }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                Text("首页")
                    .font(.system(size: MacLayout.pageTitleSize, weight: .bold, design: .default))
                    .accessibilityAddTraits(.isHeader)
                    .padding(.top, 4)

                trackShelf("最近播放", tracks: model.homeRecentlyPlayedTracks, seeAll: .recentlyPlayed)
                trackShelf("最近添加", tracks: model.homeRecentlyAddedTracks, seeAll: .recentlyAdded)
                trackShelf("收藏", tracks: model.homeFavoriteTracks, seeAll: .favorites)
                albumShelf("常听专辑", albums: model.homeTopAlbums, seeAll: .albums)
                artistShelf("常听艺术家", artists: model.homeTopArtists, seeAll: .artists)
                trackShelf("很久没听", tracks: model.homeLongUnplayedTracks, seeAll: nil)
                trackShelf("从未播放", tracks: model.homeNeverPlayedTracks, seeAll: nil)
                trackShelf("收藏里随便听", tracks: model.homeFavoriteRandomTracks, seeAll: nil)
                playlistShelf("播放列表", seeAll: .playlists)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 28)
        }
    }

    // MARK: - Shelves

    private func trackShelf(_ title: String, tracks: [Track], seeAll: MacRoute?) -> some View {
        let items = Array(tracks.prefix(14))
        guard !items.isEmpty else { return AnyView(EmptyView()) }
        return AnyView(
            VStack(alignment: .leading, spacing: 12) {
                MacSectionHeader(title: title, actionTitle: seeAll == nil ? nil : "查看全部") {
                    if let seeAll { onNavigate(seeAll) }
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 20) {
                        ForEach(items) { track in
                            MacArtworkCard(
                                title: track.title,
                                subtitle: track.artistName,
                                artworkKey: track.artworkKey,
                                size: 132,
                                colors: theme.colorTokens,
                                onOpen: { model.selectAndPlay(track) },
                                onPlay: { model.selectAndPlay(track) },
                                moreActions: macTrackMenuActions(track)
                            )
                        }
                    }
                    .padding(.horizontal, 2)
                }
            }
        )
    }

    private func albumShelf(_ title: String, albums: [Album], seeAll: MacRoute?) -> some View {
        let items = Array(albums.prefix(14))
        guard !items.isEmpty else { return AnyView(EmptyView()) }
        return AnyView(
            VStack(alignment: .leading, spacing: 12) {
                MacSectionHeader(title: title, actionTitle: seeAll == nil ? nil : "查看全部") {
                    if let seeAll { onNavigate(seeAll) }
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 20) {
                        ForEach(items) { album in
                            MacArtworkCard(
                                title: album.title,
                                subtitle: album.artistName,
                                artworkKey: album.artworkKey,
                                size: MacLayout.albumArtworkSize,
                                colors: theme.colorTokens,
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

    private func artistShelf(_ title: String, artists: [Artist], seeAll: MacRoute?) -> some View {
        let items = Array(artists.prefix(14))
        guard !items.isEmpty else { return AnyView(EmptyView()) }
        return AnyView(
            VStack(alignment: .leading, spacing: 12) {
                MacSectionHeader(title: title, actionTitle: seeAll == nil ? nil : "查看全部") {
                    if let seeAll { onNavigate(seeAll) }
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 20) {
                        ForEach(items) { artist in
                            MacArtworkCard(
                                title: artist.name,
                                subtitle: "\(artist.albumCount) 张专辑",
                                artworkKey: artist.artworkKey,
                                size: 132,
                                colors: theme.colorTokens,
                                onOpen: { onNavigate(.artist(artist)) },
                                onPlay: {
                                    let tracks = MacLibraryQuery.artistTracks(artist, model: model)
                                    if !tracks.isEmpty { model.playShuffledQueue(tracks) }
                                },
                                moreActions: [MacMenuAction(title: "随机播放", systemImage: "shuffle") {
                                    let tracks = MacLibraryQuery.artistTracks(artist, model: model)
                                    if !tracks.isEmpty { model.playShuffledQueue(tracks) }
                                }]
                            )
                        }
                    }
                    .padding(.horizontal, 2)
                }
            }
        )
    }

    private func playlistShelf(_ title: String, seeAll: MacRoute?) -> some View {
        let playlists = model.catalog.playlists.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        guard !playlists.isEmpty else { return AnyView(EmptyView()) }
        return AnyView(
            VStack(alignment: .leading, spacing: 12) {
                MacSectionHeader(title: title, actionTitle: seeAll == nil ? nil : "查看全部") {
                    if let seeAll { onNavigate(seeAll) }
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 20) {
                        ForEach(playlists.prefix(14)) { playlist in
                            MacArtworkCard(
                                title: playlist.name,
                                subtitle: nil,
                                artworkKey: nil,
                                size: MacLayout.albumArtworkSize,
                                colors: theme.colorTokens,
                                onOpen: { onNavigate(.playlist(playlist)) },
                                onPlay: {
                                    let tracks = MacLibraryQuery.playlistTracks(playlist, model: model)
                                    if !tracks.isEmpty { model.playQueue(tracks) }
                                },
                                moreActions: [MacMenuAction(title: "播放", systemImage: "play") {
                                    let tracks = MacLibraryQuery.playlistTracks(playlist, model: model)
                                    if !tracks.isEmpty { model.playQueue(tracks) }
                                }]
                            )
                        }
                    }
                    .padding(.horizontal, 2)
                }
            }
        )
    }

    private func macTrackMenuActions(_ track: Track) -> [MacMenuAction] {
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
