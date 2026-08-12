#if os(macOS)
import Domain
import LocalCatalog
import SwiftUI
import ThemeEngine

/// 播放列表总览：MacPlaylistTile（真实 mosaic 封面）。
struct MacPlaylistListView: View {
    @ObservedObject var model: AuralisAppModel
    let theme: BuiltInTheme
    var onNavigate: (MacNavigationTarget) -> Void = { _ in }

    private var playlists: [Playlist] {
        model.catalog.playlists.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: MacLayout.artworkGridGap)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 26) {
                ForEach(playlists) { playlist in
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
            .padding(.horizontal, 24)
            .padding(.top, 18)
            .padding(.bottom, 24)
        }
        .navigationTitle("播放列表")
    }
}
#endif
