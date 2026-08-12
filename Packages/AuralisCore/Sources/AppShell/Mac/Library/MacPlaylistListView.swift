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

    private var playlists: [Playlist] {
        let q = localSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.catalog.playlists
            .filter { q.isEmpty || $0.name.localizedCaseInsensitiveContains(q) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        ScrollView {
            GeometryReader { geo in
                let metrics = MacArtworkGridMetrics.albums(availableWidth: geo.size.width)
                let columns = Array(repeating: GridItem(.fixed(metrics.itemWidth), spacing: metrics.spacing), count: metrics.columnCount)
                LazyVGrid(columns: columns, spacing: 28) {
                    ForEach(playlists) { playlist in
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
            .frame(minHeight: 600)
        }
        .navigationTitle("播放列表")
        .searchable(text: $localSearch, placement: .toolbar, prompt: "在播放列表中查找")
    }
}
#endif
