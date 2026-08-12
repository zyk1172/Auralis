#if os(macOS)
import SwiftUI
import ThemeEngine
import Domain
import LocalCatalog

/// Apple Music 式 Artist Detail：名称 + Favorite/Play/Shuffle + 歌曲 + 专辑网格。
/// 无艺人照片时用代表专辑 2×2 mosaic，不伪造人物照片。
struct MacArtistView: View {
    let artist: Artist
    @ObservedObject var model: AuralisAppModel
    let theme: BuiltInTheme
    @Binding var selection: Set<GlobalID>
    var onNavigate: (MacRoute) -> Void = { _ in }

    private var tracks: [Track] { MacLibraryQuery.artistTracks(artist, model: model) }
    private var albums: [Album] { MacLibraryQuery.artistAlbums(artist, model: model) }
    private var topTracks: [Track] {
        let counts = model.playCounts
        return tracks.sorted {
            (counts[$0.id] ?? 0) > (counts[$1.id] ?? 0)
        }
    }

    private let columns = [GridItem(.adaptive(minimum: 140, maximum: 180), spacing: MacLayout.artworkGridGap)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                hero
                if !topTracks.isEmpty {
                    songsSection
                }
                if !albums.isEmpty {
                    albumsSection
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .navigationTitle(artist.name)
    }

    private var hero: some View {
        HStack(alignment: .center, spacing: 24) {
            mosaic
                .frame(width: 220, height: 220)
            VStack(alignment: .leading, spacing: 12) {
                Text(artist.name)
                    .font(.system(size: 32, weight: .bold, design: .default))
                Text("\(albums.count) 张专辑 · \(tracks.count) 首歌曲")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    MacPrimaryButton(title: "播放", systemImage: "play.fill") {
                        if !topTracks.isEmpty { model.playQueue(topTracks) }
                    }
                    MacPrimaryButton(title: "随机播放", systemImage: "shuffle", prominent: false) {
                        model.playShuffledQueue(tracks)
                    }
                    Button {
                        model.toggleArtistFavorite(artist)
                    } label: {
                        Image(systemName: model.isArtistFavorite(artist) ? "heart.fill" : "heart")
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.bordered)
                    .help(model.isArtistFavorite(artist) ? "取消收藏艺术家" : "收藏艺术家")
                    .accessibilityLabel(model.isArtistFavorite(artist) ? "取消收藏艺术家" : "收藏艺术家")
                }
            }
            Spacer()
        }
        .padding(.top, 20)
    }

    @ViewBuilder
    private var mosaic: some View {
        let reps = Array(albums.prefix(4))
        if let key = artist.artworkKey {
            ArtworkView(title: artist.name, artworkKey: key, colors: theme.colorTokens, size: 220, cornerRadius: 14)
        } else if reps.count == 4 {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 4), GridItem(.flexible(), spacing: 4)], spacing: 4) {
                ForEach(reps) { album in
                    ArtworkView(title: album.title, artworkKey: album.artworkKey, colors: theme.colorTokens, size: 106, cornerRadius: 8)
                }
            }
            .frame(width: 216, height: 216)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.quaternary)
                Text(String(artist.name.prefix(1)).uppercased())
                    .font(.system(size: 84, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 220, height: 220)
        }
    }

    private var songsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("热门歌曲")
                .font(.system(size: MacLayout.sectionTitleSize, weight: .bold))
            MacSongTable(
                tracks: topTracks,
                selection: $selection,
                model: model,
                theme: theme,
                onNavigate: onNavigate,
                numberText: { _ in nil },
                showAlbumColumn: true,
                showYearColumn: false,
                showGenreColumn: false,
                showFormatColumn: false,
                showArtwork: false,
                rowHeight: 34
            )
        }
    }

    private var albumsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("专辑")
                .font(.system(size: MacLayout.sectionTitleSize, weight: .bold))
            LazyVGrid(columns: columns, spacing: 24) {
                ForEach(albums) { album in
                    MacArtworkCard(
                        title: album.title,
                        subtitle: album.year.map(String.init),
                        artworkKey: album.artworkKey,
                        size: 150,
                        colors: theme.colorTokens,
                        onOpen: { onNavigate(.album(album)) },
                        onPlay: { model.playQueue(MacLibraryQuery.albumTracks(album, model: model)) }
                    )
                }
            }
        }
    }
}
#endif
