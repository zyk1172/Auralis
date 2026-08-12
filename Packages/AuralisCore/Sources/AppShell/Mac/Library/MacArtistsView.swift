#if os(macOS)
import SwiftUI
import ThemeEngine

/// 「艺术家」：Apple Music 式 Artwork Grid（无人物照片时用首字母占位 tile）。
struct MacArtistsView: View {
    @ObservedObject var model: AuralisAppModel
    let theme: BuiltInTheme
    var onNavigate: (MacRoute) -> Void = { _ in }

    private let columns = [GridItem(.adaptive(minimum: 140, maximum: 180), spacing: MacLayout.artworkGridGap)]

    var body: some View {
        VStack(spacing: 0) {
            MacPageHeader(title: "艺术家", subtitle: "\(model.catalog.artists.count) 位")
            ScrollView {
                LazyVGrid(columns: columns, spacing: 26) {
                    ForEach(model.catalog.artists.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) { artist in
                        MacArtworkCard(
                            title: artist.name,
                            subtitle: "\(artist.albumCount) 张专辑",
                            artworkKey: artist.artworkKey,
                            size: 150,
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
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
    }
}
#endif
