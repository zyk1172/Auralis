#if os(macOS)
import Domain
import LocalCatalog
import SwiftUI
import ThemeEngine

/// 「专辑」：自适应 Artwork Grid（MacAlbumTile）。
struct MacAlbumsView: View {
    @ObservedObject var model: AuralisAppModel
    let theme: BuiltInTheme
    var onNavigate: (MacNavigationTarget) -> Void = { _ in }

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: MacLayout.artworkGridGap)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 26) {
                ForEach(model.catalog.albums.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }) { album in
                    MacAlbumTile(
                        album: album,
                        model: model,
                        theme: theme,
                        onOpen: { onNavigate(.album(album)) },
                        onPlay: { model.playQueue(MacLibraryQuery.albumTracks(album, model: model)) },
                        moreActions: albumMoreActions(album)
                    )
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 18)
            .padding(.bottom, 24)
        }
        .navigationTitle("专辑")
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
