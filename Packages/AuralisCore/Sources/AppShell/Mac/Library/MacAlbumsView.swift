#if os(macOS)
import SwiftUI
import ThemeEngine
import Domain
import LocalCatalog

/// 「专辑」：Apple Music 式自适应 Artwork Grid，hover Play / More。
struct MacAlbumsView: View {
    @ObservedObject var model: AuralisAppModel
    let theme: BuiltInTheme
    var onNavigate: (MacRoute) -> Void = { _ in }

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: MacLayout.artworkGridGap)]

    var body: some View {
        VStack(spacing: 0) {
            MacPageHeader(title: "专辑", subtitle: "\(model.catalog.albums.count) 张")
            ScrollView {
                LazyVGrid(columns: columns, spacing: 26) {
                    ForEach(model.catalog.albums) { album in
                        MacArtworkCard(
                            title: album.title,
                            subtitle: album.artistName,
                            artworkKey: album.artworkKey,
                            size: MacLayout.albumArtworkSize,
                            colors: theme.colorTokens,
                            onOpen: { onNavigate(.album(album)) },
                            onPlay: {
                                model.playQueue(MacLibraryQuery.albumTracks(album, model: model))
                            },
                            moreActions: albumMoreActions(album)
                        )
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
    }

    private func albumMoreActions(_ album: Album) -> [MacMenuAction] {
        let isFavorite = model.isAlbumFavorite(album)
        let artist = model.catalog.artists.first { $0.id == album.artistID && $0.serverID == album.serverID }
        return [
            MacMenuAction(title: isFavorite ? "取消收藏专辑" : "收藏专辑", systemImage: "heart") {
                model.toggleAlbumFavorite(album)
            },
            MacMenuAction(title: "随机播放专辑", systemImage: "shuffle") {
                model.playShuffledQueue(MacLibraryQuery.albumTracks(album, model: model))
            }
        ] + (artist.map { a in
            [MacMenuAction(title: "前往艺术家", systemImage: "person.2") { onNavigate(.artist(a)) }]
        } ?? [])
    }
}
#endif
