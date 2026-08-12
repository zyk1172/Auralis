#if os(macOS)
import SwiftUI
import ThemeEngine
import Domain

/// 播放列表总览：Apple Music 式 Grid（真实歌单封面或 2×2 mosaic 占位）。
struct MacPlaylistListView: View {
    @ObservedObject var model: AuralisAppModel
    let theme: BuiltInTheme
    var onNavigate: (MacRoute) -> Void = { _ in }

    private var playlists: [Playlist] {
        model.catalog.playlists.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: MacLayout.artworkGridGap)]

    var body: some View {
        VStack(spacing: 0) {
            MacPageHeader(title: "播放列表", subtitle: "\(playlists.count) 个")
            ScrollView {
                LazyVGrid(columns: columns, spacing: 26) {
                    ForEach(playlists) { playlist in
                        MacArtworkCard(
                            title: playlist.name,
                            subtitle: playlistComment(playlist),
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
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
    }

    private func playlistComment(_ playlist: Playlist) -> String? {
        let count = MacLibraryQuery.playlistTracks(playlist, model: model).count
        return "\(count) 首"
    }
}
#endif
