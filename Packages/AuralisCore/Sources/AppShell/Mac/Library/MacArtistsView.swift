#if os(macOS)
import Domain
import LocalCatalog
import SwiftUI
import ThemeEngine

/// 「艺术家」：Artist Tile（真实图圆形 / 专辑 mosaic / monogram）。
struct MacArtistsView: View {
    @ObservedObject var model: AuralisAppModel
    let theme: BuiltInTheme
    var onNavigate: (MacNavigationTarget) -> Void = { _ in }

    private let columns = [GridItem(.adaptive(minimum: 140, maximum: 180), spacing: MacLayout.artworkGridGap)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 26) {
                ForEach(model.catalog.artists.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) { artist in
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
            .padding(.horizontal, 24)
            .padding(.top, 18)
            .padding(.bottom, 24)
        }
        .navigationTitle("艺术家")
    }
}
#endif
