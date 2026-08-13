#if os(macOS)
import Domain
import LocalCatalog
import SwiftUI
import ThemeEngine

/// 全局搜索（Sidebar 一级页）：自身持有自定义搜索框（不用系统 .searchable，
/// 规避 macOS 27 Beta 中 NavigationSplitView + .searchable 的框架崩溃）。
/// 只允许 canonical 实体参与真实动作；未解析实体显示不可用行，不构造假 Track。
struct MacSearchView: View {
    @ObservedObject var model: AuralisAppModel
    let theme: BuiltInTheme
    var onNavigate: (MacNavigationTarget) -> Void = { _ in }

    @State private var query = ""
    @FocusState private var searchFocused: Bool
    @State private var state: MacSearchState = .idle
    @State private var tracks: [CatalogTrackSummary] = []
    @State private var albums: [CatalogAlbumSummary] = []
    @State private var artists: [CatalogArtistSummary] = []
    @State private var playlists: [Playlist] = []

    enum MacSearchState: Equatable {
        case idle
        case searching
        case results
        case empty
    }

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(spacing: 0) {
            MacPageSearchHeader(
                text: $query,
                prompt: "搜索",
                onSubmit: {
                    let trimmed = trimmedQuery
                    if !trimmed.isEmpty { model.recordSearch(trimmed) }
                },
                focus: $searchFocused
            )
            Divider()
            Group {
                switch state {
                case .idle:
                    idleContent
                case .searching:
                    VStack(spacing: 12) {
                        Spacer()
                        ProgressView().controlSize(.small)
                        Text("正在搜索你的资料库")
                            .font(.body)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .results:
                    resultsContent
                case .empty:
                    ContentUnavailableView("未找到结果", systemImage: "magnifyingglass",
                                           description: Text("没有找到与「\(trimmedQuery)」匹配的内容。"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .onAppear {
            // 进入 Search 页（含 ⌘F）时聚焦搜索框。
            searchFocused = true
        }
        .task(id: trimmedQuery) { await runSearch() }
        .onReceive(NotificationCenter.default.publisher(for: MacCommand.search)) { _ in
            // 已在搜索页时再次按 ⌘F：重新聚焦搜索框。
            searchFocused = true
        }
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
                } else {
                    VStack(spacing: 14) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 44))
                            .foregroundStyle(.secondary)
                        Text("搜索你的资料库")
                            .font(.title3.weight(.semibold))
                        Text("查找歌曲、专辑、艺术家和播放列表。")
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 60)
                }
                if !recentArtists.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        sectionTitle("最近播放的艺术家")
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 200, maximum: 240), spacing: 16)], alignment: .leading) {
                            ForEach(recentArtists, id: \.self) { artist in
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
            }
            .padding(24)
        }
    }

    /// 最近艺术家：按 (serverID, artistID) 投影解析，禁止用 Name 当 identity。
    private var recentArtists: [Artist] {
        MacSearchRecentArtists.resolve(tracks: model.recentlyPlayedTracks, model: model)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(.headline)
    }

    // MARK: - 搜索

    private func runSearch() async {
        let q = trimmedQuery
        guard !q.isEmpty else {
            tracks = []; albums = []; artists = []; playlists = []
            state = .idle
            return
        }
        state = .searching
        // 快速输入防抖：取消上一个 task。
        try? await Task.sleep(nanoseconds: 200_000_000)
        guard !Task.isCancelled else { return }
        let store = model.catalogCoordinator.store
        let serverID = model.catalog.activeServerID
        tracks = (try? await store.searchTracks(query: q, serverID: serverID)) ?? []
        albums = (try? await store.searchAlbums(query: q, serverID: serverID)) ?? []
        artists = (try? await store.searchArtists(query: q, serverID: serverID)) ?? []
        playlists = model.catalog.playlists.filter { $0.name.localizedCaseInsensitiveContains(q) }
        guard !Task.isCancelled else { return }
        if tracks.isEmpty && albums.isEmpty && artists.isEmpty && playlists.isEmpty {
            state = .empty
        } else {
            state = .results
        }
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
            }
            .padding(24)
        }
    }

    @ViewBuilder
    private func resultSongRow(_ summary: CatalogTrackSummary) -> some View {
        if let resolved = model.track(for: summary.globalID) {
            Button {
                MacUITrace.action("playTrack", summary.globalID.description)
                model.playQueue([resolved])
            } label: {
                HStack(spacing: 12) {
                    ArtworkView(title: summary.albumTitle, artworkKey: resolved.artworkKey, colors: theme.colorTokens, size: 40, cornerRadius: 6)
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
            .macTrackContextMenu(track: resolved, model: model, onNavigate: onNavigate)
        } else {
            HStack(spacing: 12) {
                ArtworkView(title: summary.albumTitle, artworkKey: nil, colors: theme.colorTokens, size: 40, cornerRadius: 6)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(summary.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Text("该项目已不在本地资料库中")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(summary.title)，已不在本地资料库")
        }
    }

    @ViewBuilder
    private func albumResultTile(_ summary: CatalogAlbumSummary) -> some View {
        if let album = model.catalog.albums.first(where: { $0.serverID == summary.globalID.serverID && $0.id.rawValue == summary.globalID.remoteID }) {
            MacAlbumTile(
                album: album,
                model: model,
                theme: theme,
                onOpen: { onNavigate(.album(album)) },
                onPlay: { model.playQueue(MacLibraryQuery.albumTracks(album, model: model)) }
            )
        } else {
            VStack(alignment: .leading, spacing: 7) {
                ArtworkView(title: summary.title, artworkKey: nil, colors: theme.colorTokens, size: MacUIVisualTokens.Artwork.searchResultSize, cornerRadius: MacUIVisualTokens.Artwork.searchResultCornerRadius)
                    .accessibilityHidden(true)
                Text(summary.title).font(.system(size: 13, weight: .medium)).lineLimit(1).foregroundStyle(.primary)
                Text("该项目已不在本地资料库中").font(.system(size: 12)).foregroundStyle(.tertiary).lineLimit(1)
            }
            .frame(width: MacUIVisualTokens.Artwork.searchResultSize, alignment: .leading)
        }
    }

    @ViewBuilder
    private func artistResultRow(_ summary: CatalogArtistSummary) -> some View {
        if let artist = model.catalog.artists.first(where: { $0.serverID == summary.globalID.serverID && $0.id.rawValue == summary.globalID.remoteID }) {
            Button {
                onNavigate(.artist(artist))
            } label: {
                HStack(spacing: 10) {
                    ArtworkView(title: artist.name, artworkKey: artist.artworkKey, colors: theme.colorTokens, size: 44, cornerRadius: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(artist.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        Text("\(artist.albumCount) 张专辑").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            HStack(spacing: 10) {
                ArtworkView(title: summary.name, artworkKey: nil, colors: theme.colorTokens, size: 44, cornerRadius: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(summary.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Text("该项目已不在本地资料库中").font(.system(size: 12)).foregroundStyle(.tertiary).lineLimit(1)
                }
                Spacer()
            }
        }
    }
}

/// 艺术家双键身份（serverID + artistID）。
struct ArtistRouteIdentity: Hashable {
    let serverID: ServerID
    let remoteID: String
}

/// 最近艺术家解析：按 (serverID, artistID) 双键投影，禁止用 Name 当 identity。
@MainActor
enum MacSearchRecentArtists {
    static func resolve(tracks: [Track], model: AuralisAppModel) -> [Artist] {
        var seen = Set<ArtistRouteIdentity>()
        var result: [Artist] = []
        for track in tracks {
            let id = ArtistRouteIdentity(serverID: track.serverID, remoteID: track.artistID.rawValue)
            guard seen.insert(id).inserted else { continue }
            if let artist = model.catalog.artists.first(where: { $0.serverID == track.serverID && $0.id == track.artistID }) {
                result.append(artist)
                if result.count >= 8 { break }
            }
        }
        return result
    }
}
#endif
