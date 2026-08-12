#if os(macOS)
import Domain
import LocalCatalog
import SwiftUI
import ThemeEngine

/// 全局搜索（Sidebar 一级页，REFERENCE_A）：自身持有系统 .searchable。
/// 空查询 → Landing；输入后 → 歌曲/专辑/艺术家/歌单 分类结果。
struct MacSearchView: View {
    @ObservedObject var model: AuralisAppModel
    let theme: BuiltInTheme
    var onNavigate: (MacNavigationTarget) -> Void = { _ in }

    @State private var query = ""
    @State private var tracks: [CatalogTrackSummary] = []
    @State private var albums: [CatalogAlbumSummary] = []
    @State private var artists: [CatalogArtistSummary] = []
    @State private var playlists: [Playlist] = []

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        Group {
            if trimmedQuery.isEmpty {
                idleContent
            } else {
                resultsContent
            }
        }
        .searchable(text: $query, placement: .toolbar, prompt: "搜索")
        .onSubmit(of: .search) {
            let trimmed = trimmedQuery
            if !trimmed.isEmpty { model.recordSearch(trimmed) }
        }
        .task(id: trimmedQuery) { await runSearch() }
    }

    // MARK: - Landing

    private var idleContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                if !model.recentSearches.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        sectionTitle("最近搜索")
                        HStack(spacing: 8) {
                            ForEach(model.recentSearches.prefix(8), id: \.self) { term in
                                Button(term) { query = term }
                                    .buttonStyle(.bordered)
                            }
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    sectionTitle("浏览资料库")
                    HStack(spacing: 10) {
                        browseEntry("歌曲", .songs)
                        browseEntry("专辑", .albums)
                        browseEntry("艺术家", .artists)
                        browseEntry("流派", .genres)
                        browseEntry("播放列表", .playlists)
                    }
                }
                if !recentArtists.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        sectionTitle("最近播放的艺术家")
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 200, maximum: 240), spacing: 16)], alignment: .leading) {
                            ForEach(recentArtists, id: \.self) { name in
                                if let artist = model.catalog.artists.first(where: { $0.name == name }) {
                                    Button {
                                        onNavigate(.artist(artist))
                                    } label: {
                                        HStack(spacing: 10) {
                                            ArtworkView(title: artist.name, artworkKey: artist.artworkKey, colors: theme.colorTokens, size: 40, cornerRadius: 20)
                                            Text(artist.name).lineLimit(1)
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
                if !model.catalog.playlists.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        sectionTitle("常用歌单")
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 200, maximum: 240), spacing: 16)], alignment: .leading) {
                            ForEach(model.catalog.playlists.prefix(6)) { playlist in
                                Button {
                                    onNavigate(.playlist(playlist))
                                } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: "music.note.list")
                                            .foregroundStyle(theme.colorTokens.accent.color)
                                        Text(playlist.name).lineLimit(1)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                Text("搜索歌曲、专辑、艺术家和歌单。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
        }
    }

    private var recentArtists: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for track in model.recentlyPlayedTracks {
            if seen.insert(track.artistName).inserted {
                result.append(track.artistName)
                if result.count >= 8 { break }
            }
        }
        return result
    }

    private func browseEntry(_ title: String, _ route: MacSidebarDestination) -> some View {
        Button {
            onNavigate(.sidebar(route))
        } label: {
            Label(title, systemImage: route.symbol)
                .padding(.vertical, 6)
                .padding(.horizontal, 12)
        }
        .buttonStyle(.bordered)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(.headline)
    }

    // MARK: - Results

    private var resultsContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if !tracks.isEmpty {
                    sectionTitle("歌曲（\(tracks.count)）")
                    VStack(spacing: 0) {
                        ForEach(tracks.prefix(20)) { summary in
                            resultSongRow(summary)
                            if summary.id != tracks.prefix(20).last?.id { Divider() }
                        }
                    }
                }
                if !albums.isEmpty {
                    sectionTitle("专辑（\(albums.count)）")
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 20)], alignment: .leading) {
                        ForEach(albums.prefix(12)) { summary in
                            albumResultTile(summary)
                        }
                    }
                }
                if !artists.isEmpty {
                    sectionTitle("艺术家（\(artists.count)）")
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 180, maximum: 220), spacing: 16)], alignment: .leading) {
                        ForEach(artists.prefix(12)) { summary in
                            artistResultRow(summary)
                        }
                    }
                }
                if !playlists.isEmpty {
                    sectionTitle("歌单（\(playlists.count)）")
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 200, maximum: 240), spacing: 16)], alignment: .leading) {
                        ForEach(playlists.prefix(8)) { playlist in
                            Button {
                                onNavigate(.playlist(playlist))
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "music.note.list")
                                        .foregroundStyle(theme.colorTokens.accent.color)
                                    Text(playlist.name).lineLimit(1)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if tracks.isEmpty && albums.isEmpty && artists.isEmpty && playlists.isEmpty {
                    ContentUnavailableView("未找到结果", systemImage: "magnifyingglass",
                                           description: Text("没有找到与「\(trimmedQuery)」匹配的内容。"))
                        .frame(maxWidth: .infinity, minHeight: 220)
                }
            }
            .padding(24)
        }
    }

    private func runSearch() async {
        let q = trimmedQuery
        guard !q.isEmpty else {
            tracks = []; albums = []; artists = []; playlists = []
            return
        }
        let store = model.catalogCoordinator.store
        let serverID = model.catalog.activeServerID
        tracks = (try? await store.searchTracks(query: q, serverID: serverID)) ?? []
        albums = (try? await store.searchAlbums(query: q, serverID: serverID)) ?? []
        artists = (try? await store.searchArtists(query: q, serverID: serverID)) ?? []
        playlists = model.catalog.playlists.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    private func resultSongRow(_ summary: CatalogTrackSummary) -> some View {
        let resolved = model.track(for: summary.globalID)
        return Button {
            if let track = resolved { model.playQueue([track]) }
        } label: {
            HStack(spacing: 12) {
                ArtworkView(title: summary.albumTitle, artworkKey: resolved?.artworkKey, colors: theme.colorTokens, size: 40, cornerRadius: 6)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(summary.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Text(summary.artistName).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Text(MacFormat.time(summary.duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .macTrackContextMenu(track: resolved ?? placeholderTrack(summary), model: model, onNavigate: onNavigate)
    }

    private func albumResultTile(_ summary: CatalogAlbumSummary) -> some View {
        let album = model.catalog.albums.first { $0.serverID == summary.globalID.serverID && $0.id.rawValue == summary.globalID.remoteID }
        let placeholder = Album(id: AlbumID(rawValue: summary.globalID.remoteID), serverID: summary.globalID.serverID, artistID: ArtistID(rawValue: ""), title: summary.title, artistName: summary.artistName, artworkKey: album?.artworkKey)
        return MacAlbumTile(
            album: album ?? placeholder,
            model: model,
            theme: theme,
            onOpen: { if let album { onNavigate(.album(album)) } },
            onPlay: { if let album { model.playQueue(MacLibraryQuery.albumTracks(album, model: model)) } }
        )
    }

    private func artistResultRow(_ summary: CatalogArtistSummary) -> some View {
        let artist = model.catalog.artists.first { $0.serverID == summary.globalID.serverID && $0.id.rawValue == summary.globalID.remoteID }
        return Button {
            if let artist { onNavigate(.artist(artist)) }
        } label: {
            HStack(spacing: 10) {
                ArtworkView(title: artist?.name ?? summary.name, artworkKey: artist?.artworkKey, colors: theme.colorTokens, size: 44, cornerRadius: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(summary.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Text("\(summary.albumCount) 张专辑").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func placeholderTrack(_ summary: CatalogTrackSummary) -> Track {
        Track(
            id: TrackID(rawValue: summary.globalID.remoteID),
            serverID: summary.globalID.serverID,
            albumID: AlbumID(rawValue: ""),
            artistID: ArtistID(rawValue: ""),
            title: summary.title,
            artistName: summary.artistName,
            albumTitle: summary.albumTitle,
            duration: summary.duration
        )
    }
}
#endif
