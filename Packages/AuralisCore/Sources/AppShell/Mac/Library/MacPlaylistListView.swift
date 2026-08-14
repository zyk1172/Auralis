#if os(macOS)
import Domain
import LocalCatalog
import SwiftUI
import ThemeEngine

/// 播放列表总览：真实 mosaic 封面 + 本地搜索「在播放列表中查找」。
struct MacPlaylistListView: View {
    @ObservedObject var model: AuralisAppModel
    let theme: BuiltInTheme
    var onNavigate: (MacNavigationTarget) -> Void = { _ in }

    @State private var localSearch = ""
    @State private var visiblePlaylists: [Playlist] = []

    private var derivationKey: String {
        "\(model.catalogRevision)|\(localSearch)"
    }

    private func rebuildVisiblePlaylists() {
        let q = localSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        visiblePlaylists = model.catalog.playlists
            .filter { q.isEmpty || $0.name.localizedCaseInsensitiveContains(q) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        VStack(spacing: 0) {
            MacPageSearchHeader(text: $localSearch, prompt: "在播放列表中查找")
            Divider()
            GeometryReader { geo in
                if visiblePlaylists.isEmpty {
                    ContentUnavailableView {
                        Label("暂无播放列表", systemImage: "music.note.list")
                    } description: {
                        Text("你可以创建播放列表，也可以使用音乐服务器中已经存在的播放列表。")
                    } actions: {
                        Button("新建播放列表") {
                            NotificationCenter.default.post(name: MacCommand.newPlaylist, object: nil)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else {
                    let metrics = MacArtworkGridMetrics.albums(availableWidth: geo.size.width)
                    let columns = Array(repeating: GridItem(.fixed(metrics.itemWidth), spacing: metrics.spacing), count: metrics.columnCount)
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 28) {
                            ForEach(visiblePlaylists) { playlist in
                                MacPlaylistTile(
                                    playlist: playlist,
                                    model: model,
                                    theme: theme,
                                    size: metrics.itemWidth,
                                    onOpen: { onNavigate(.playlist(playlist)) },
                                    onPlay: {
                                        let tracks = MacLibraryQuery.playlistTracks(playlist, model: model)
                                        if !tracks.isEmpty { model.playQueue(tracks) }
                                    }
                                )
                            }
                        }
                        .padding(.horizontal, metrics.horizontalPadding)
                        .padding(.vertical, 20)
                    }
                }
            }
        }
        .navigationTitle("播放列表")
        .task(id: derivationKey) {
            rebuildVisiblePlaylists()
        }
    }
}
#endif
