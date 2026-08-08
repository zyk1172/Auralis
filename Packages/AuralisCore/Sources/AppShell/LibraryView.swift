import DesignSystem
import Domain
import SwiftUI
import ThemeEngine

struct LibraryView: View {
    @ObservedObject var model: AuralisAppModel
    let theme: BuiltInTheme
    @State private var scope = LibraryScope.albums
    @State private var playlistTarget: Track?

    var body: some View {
        VStack(spacing: 0) {
            Picker("资料类型", selection: $scope) {
                ForEach(LibraryScope.allCases) { item in Text(item.title).tag(item) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, AuralisSpacing.large)
            .padding(.vertical, AuralisSpacing.small)
            .onChange(of: scope) { _, _ in Haptics.selection() }
            Divider()
            scopeContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(theme.colorTokens.background.color)
        .sheet(item: $playlistTarget) { track in
            AddToPlaylistSheet(model: model, theme: theme, track: track)
        }
    }

    @ViewBuilder
    private var scopeContent: some View {
        switch scope {
        case .tracks: trackList
        case .albums: albumGrid
        case .artists: artistList
        case .playlists: playlistGrid
        case .favorites: favoriteList
        case .genres: genreList
        }
    }

    private var trackList: some View {
        Group {
            if model.catalog.tracks.isEmpty {
                AuralisEmptyState(
                    icon: "music.note",
                    title: "资料库还没有歌曲",
                    message: "连接服务器并同步后，这里会列出全部歌曲；也可以从「首页」先随机播放几首。",
                    colors: theme.colorTokens
                )
            } else {
                List(model.catalog.tracks) { track in
                    TrackRow(track: track, isCurrent: track.id == model.currentTrack.id, isDownloaded: model.isDownloaded(track), theme: theme)
                        .contentShape(Rectangle())
                        .onTapGesture { model.selectAndPlay(track) }
                        .contextMenu {
                            Button("立即播放") { model.selectAndPlay(track) }
                            Button("下一首播放") { insertNext(track) }
                            Button("加入队列") {
                                if !model.queue.contains(where: { $0.id == track.id }) {
                                    model.queue.append(track)
                                }
                            }
                            Button("添加到歌单") { playlistTarget = track }
                            Divider()
                            if model.isDownloaded(track) {
                                Button("删除本地缓存", role: .destructive) { model.removeDownload(track) }
                            } else if model.isDownloading(track) {
                                Button("取消下载") { model.cancelDownload(track) }
                            } else {
                                Button("下载到本地") { model.download(track) }
                            }
                            Divider()
                            Button(track.isFavorite ? "取消收藏" : "收藏") { model.toggleFavorite(track) }
                        }
                }
                .listStyle(.plain)
            }
        }
    }

    private var albumGrid: some View {
        Group {
            if model.catalog.albums.isEmpty {
                AuralisEmptyState(
                    icon: "square.stack",
                    title: "还没有专辑",
                    message: "当前资料库暂无专辑，可能需要同步或扫描音乐库。",
                    colors: theme.colorTokens
                )
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 142), spacing: AuralisSpacing.medium)], spacing: AuralisSpacing.large) {
                        ForEach(model.catalog.albums) { album in
                            VStack(alignment: .leading, spacing: AuralisSpacing.xSmall) {
                                GeometryReader { geo in
                                    ArtworkView(title: album.title, artworkKey: album.artworkKey, colors: theme.colorTokens, size: max(geo.size.width, 1))
                                }
                                .aspectRatio(1, contentMode: .fit)
                                .frame(minHeight: 1)
                                Text(album.title).font(.headline).lineLimit(1)
                                Text(album.artistName).font(.caption).foregroundStyle(theme.colorTokens.secondaryText.color).lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .foregroundStyle(theme.colorTokens.primaryText.color)
                            .contentShape(Rectangle())
                            .onTapGesture { model.browseDestination = .album(album) }
                            .contextMenu {
                                Button("播放全部") {
                                    let tracks = model.catalog.tracks.filter { $0.albumID == album.id }
                                    model.playTracks(tracks)
                                }
                                Button(model.isAlbumFavorite(album) ? "取消收藏" : "收藏专辑") { model.toggleAlbumFavorite(album) }
                                Button("下载专辑") {
                                    model.downloadAll(model.catalog.tracks.filter { $0.albumID == album.id })
                                }
                            }
                        }
                    }
                    .padding()
                }
            }
        }
    }

    private var artistList: some View {
        Group {
            if model.catalog.artists.isEmpty {
                AuralisEmptyState(
                    icon: "person.2",
                    title: "还没有艺术家",
                    message: "当前资料库暂无艺术家，可能需要同步或扫描音乐库。",
                    colors: theme.colorTokens
                )
            } else {
                List(model.catalog.artists) { artist in
                    HStack {
                        ArtworkView(title: artist.name, artworkKey: artist.artworkKey, colors: theme.colorTokens, size: 48, cornerRadius: 24)
                        VStack(alignment: .leading) {
                            Text(artist.name).font(.headline)
                            Text("\(artist.albumCount) 张专辑").font(.caption).foregroundStyle(theme.colorTokens.secondaryText.color)
                        }
                    }
                    .foregroundStyle(theme.colorTokens.primaryText.color)
                    .contentShape(Rectangle())
                    .onTapGesture { model.browseDestination = .artist(artist) }
                    .contextMenu {
                        Button("播放全部") {
                            model.playTracks(model.catalog.tracks.filter { $0.artistID == artist.id })
                        }
                        Button(model.isArtistFavorite(artist) ? "取消收藏" : "收藏艺术家") { model.toggleArtistFavorite(artist) }
                        Button("下载全部") {
                            model.downloadAll(model.catalog.tracks.filter { $0.artistID == artist.id })
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    /// 流派浏览：按服务器 getGenres 与曲目标签合并后的流派展示，卡片式、按实际歌曲数降序。
    /// 显示名使用中文翻译（GenreLocalization）；点击进入该流派歌曲列表。
    private var genreList: some View {
        Group {
            let genres = Self.sortedGenres(model)
            if genres.isEmpty {
                AuralisEmptyState(
                    icon: "music.quarternote.3",
                    title: "还没有流派",
                    message: "服务器返回的流派（来自音乐文件内嵌标签）会显示在这里；连接并同步后即可按流派浏览。",
                    colors: theme.colorTokens
                )
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 150), spacing: AuralisSpacing.medium)],
                        spacing: AuralisSpacing.medium
                    ) {
                        ForEach(genres, id: \.genre.id) { item in
                            Button {
                                model.browseDestination = .genre(item.genre)
                            } label: {
                                VStack(alignment: .leading, spacing: AuralisSpacing.small) {
                                    HStack {
                                        Image(systemName: "music.quarternote.3")
                                            .font(.title3)
                                            .foregroundStyle(theme.colorTokens.accent.color)
                                        Spacer()
                                        Text("\(item.count)")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(theme.colorTokens.secondaryText.color)
                                    }
                                    Text(GenreLocalization.displayName(for: item.genre.name))
                                        .font(.headline)
                                        .lineLimit(1)
                                        .foregroundStyle(theme.colorTokens.primaryText.color)
                                    Text("\(item.count) 首")
                                        .font(.caption)
                                        .foregroundStyle(theme.colorTokens.secondaryText.color)
                                }
                                .padding(AuralisSpacing.medium)
                                .frame(maxWidth: .infinity, minHeight: 86, alignment: .topLeading)
                                .background(theme.colorTokens.surface.color)
                                .clipShape(RoundedRectangle(cornerRadius: AuralisRadius.medium, style: .continuous))
                            }
                            .buttonStyle(HapticPlainButtonStyle())
                        }
                    }
                    .padding(AuralisSpacing.medium)
                }
            }
        }
        .task { model.refreshGenres() }
    }

    /// 聚合流派并按实际歌曲数降序（数量相同按名称排序）。
    private static func sortedGenres(_ model: AuralisAppModel) -> [(genre: Genre, count: Int)] {
        let items: [(genre: Genre, count: Int)] = model.catalog.genres.map { genre in
            (genre, model.tracks(for: genre).count)
        }
        return items.sorted { left, right in
            if left.count != right.count { return left.count > right.count }
            return left.genre.name.localizedStandardCompare(right.genre.name) == .orderedAscending
        }
    }

    /// 歌单封面：取歌单内第一首歌曲的封面（同一专辑多首歌曲共享封面）。
    private static func firstTrackArtworkKey(_ model: AuralisAppModel, _ playlist: Playlist) -> String? {
        guard let firstID = playlist.trackIDs.first else { return nil }
        return model.catalog.tracks.first { $0.id == firstID }?.artworkKey
    }



    private var playlistGrid: some View {
        Group {
            if model.catalog.playlists.isEmpty {
                AuralisEmptyState(
                    icon: "music.note.list",
                    title: "还没有歌单",
                    message: "在服务器上创建歌单后，这里会列出所有歌单。",
                    colors: theme.colorTokens
                )
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 142), spacing: AuralisSpacing.medium)], spacing: AuralisSpacing.large) {
                        ForEach(model.catalog.playlists) { playlist in
                            VStack(alignment: .leading, spacing: AuralisSpacing.xSmall) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: AuralisRadius.medium, style: .continuous)
                                        .fill(theme.colorTokens.surface.color)
                                        .aspectRatio(1, contentMode: .fit)
                                    if let coverKey = Self.firstTrackArtworkKey(model, playlist) {
                                        GeometryReader { geo in
                                            ArtworkView(title: playlist.name, artworkKey: coverKey, colors: theme.colorTokens, size: max(geo.size.width, 1))
                                        }
                                        .aspectRatio(1, contentMode: .fit)
                                        .frame(minHeight: 1)
                                        .clipShape(RoundedRectangle(cornerRadius: AuralisRadius.medium, style: .continuous))
                                    } else {
                                        Image(systemName: "music.note.list")
                                            .font(.system(size: 40))
                                            .foregroundStyle(theme.colorTokens.accent.color)
                                    }
                                }
                                Text(playlist.name).font(.headline).lineLimit(1)
                                Text("\(playlist.trackIDs.count) 首").font(.caption).foregroundStyle(theme.colorTokens.secondaryText.color).lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .foregroundStyle(theme.colorTokens.primaryText.color)
                            .contentShape(Rectangle())
                            .onTapGesture { model.browseDestination = .playlist(playlist) }
                        }
                    }
                    .padding()
                }
            }
        }
    }

    private var favoriteList: some View {
        Group {
            if model.favoriteTracks.isEmpty {
                AuralisEmptyState(
                    icon: "heart",
                    title: "还没有收藏",
                    message: "在播放页或歌曲菜单中点心形收藏后，会出现在这里。",
                    colors: theme.colorTokens
                )
            } else {
                List(model.favoriteTracks) { track in
                    TrackRow(track: track, isCurrent: track.id == model.currentTrack.id, theme: theme)
                        .contentShape(Rectangle())
                        .onTapGesture { model.selectAndPlay(track) }
                        .contextMenu {
                            Button("立即播放") { model.selectAndPlay(track) }
                            Button("下一首播放") { insertNext(track) }
                            Button(track.isFavorite ? "取消收藏" : "收藏") { model.toggleFavorite(track) }
                        }
                }
                .listStyle(.plain)
            }
        }
    }

    private func insertNext(_ track: Track) {
        guard let currentIndex = model.queue.firstIndex(where: { $0.id == model.currentTrack.id }) else {
            model.queue.insert(track, at: 0)
            return
        }
        model.queue.insert(track, at: min(currentIndex + 1, model.queue.count))
    }
}

private enum LibraryScope: String, CaseIterable, Identifiable {
    case albums, tracks, artists, playlists, favorites, genres
    var id: String { rawValue }
    var title: String {
        switch self {
        case .albums: String(localized: "专辑")
        case .tracks: String(localized: "歌曲")
        case .artists: String(localized: "艺术家")
        case .playlists: String(localized: "歌单")
        case .favorites: String(localized: "收藏")
        case .genres: String(localized: "流派")
        }
    }
}

struct TrackRow: View {
    let track: Track
    let isCurrent: Bool
    var isDownloaded: Bool = false
    let theme: BuiltInTheme

    var body: some View {
        HStack(spacing: AuralisSpacing.medium) {
            ArtworkView(title: track.albumTitle, artworkKey: track.artworkKey, colors: theme.colorTokens, size: 48, cornerRadius: 10)
            VStack(alignment: .leading, spacing: 3) {
                Text(track.title)
                    .font(.body.weight(isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? theme.colorTokens.accent.color : theme.colorTokens.primaryText.color)
                Text("\(track.artistName) · \(track.albumTitle)")
                    .font(.caption)
                    .foregroundStyle(theme.colorTokens.secondaryText.color)
                    .lineLimit(1)
            }
            Spacer()
            if isDownloaded {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.caption)
                    .foregroundStyle(theme.colorTokens.success.color)
                    .accessibilityLabel("已下载")
            }
            if track.isFavorite {
                Image(systemName: "heart.fill")
                    .foregroundStyle(theme.colorTokens.accent.color)
                    .accessibilityLabel("已收藏")
            }
            Text(formatDuration(track.duration))
                .font(.caption.monospacedDigit())
                .foregroundStyle(theme.colorTokens.secondaryText.color)
        }
        .padding(.vertical, 3)
    }
}

func formatDuration(_ value: TimeInterval) -> String {
    let seconds = max(0, Int(value))
    return String(format: "%d:%02d", seconds / 60, seconds % 60)
}
