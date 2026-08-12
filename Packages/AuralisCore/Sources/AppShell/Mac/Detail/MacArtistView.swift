#if os(macOS)
import Domain
import LocalCatalog
import SwiftUI
import ThemeEngine

/// Artist Detail：Hero（mosaic/monogram）+ 常听歌曲 + 专辑网格。
/// 「常听歌曲」按本机播放次数排序（用户个人常听，不是外部热门），单曲行不嵌套 Table。
struct MacArtistView: View {
    let artist: Artist
    @ObservedObject var model: AuralisAppModel
    let theme: BuiltInTheme
    @Binding var selection: Set<GlobalID>
    var onNavigate: (MacNavigationTarget) -> Void = { _ in }

    private var tracks: [Track] { MacLibraryQuery.artistTracks(artist, model: model) }
    private var albums: [Album] { MacLibraryQuery.artistAlbums(artist, model: model) }

    /// 用户自己的常听歌曲：按本机播放次数降序。
    private var topTracks: [Track] {
        let counts = model.playCounts
        return tracks.sorted { (counts[$0.id] ?? 0) > (counts[$1.id] ?? 0) }
    }

    private let columns = [GridItem(.adaptive(minimum: 140, maximum: 180), spacing: MacLayout.artworkGridGap)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                hero
                if !topTracks.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("常听歌曲")
                            .font(.system(size: MacLayout.sectionTitleSize, weight: .bold))
                        MacDetailTrackList(
                            tracks: topTracks,
                            model: model,
                            theme: theme,
                            showAlbum: true,
                            onNavigate: onNavigate
                        )
                    }
                }
                if !albums.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("专辑")
                            .font(.system(size: MacLayout.sectionTitleSize, weight: .bold))
                        LazyVGrid(columns: columns, spacing: 24) {
                            ForEach(albums) { album in
                                MacAlbumTile(
                                    album: album,
                                    model: model,
                                    theme: theme,
                                    size: 150,
                                    onOpen: { onNavigate(.album(album)) },
                                    onPlay: { model.playQueue(MacLibraryQuery.albumTracks(album, model: model)) }
                                )
                            }
                        }
                    }
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
                .frame(width: 200, height: 200)
            VStack(alignment: .leading, spacing: 10) {
                Text(artist.name)
                    .font(.system(size: 30, weight: .bold, design: .default))
                Text("\(albums.count) 张专辑 · \(tracks.count) 首歌曲")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Button {
                        if !topTracks.isEmpty { model.playQueue(topTracks) }
                    } label: {
                        Label("播放", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    Button {
                        model.playShuffledQueue(tracks)
                    } label: {
                        Label("随机播放", systemImage: "shuffle")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    Button {
                        model.toggleArtistFavorite(artist)
                    } label: {
                        Image(systemName: model.isArtistFavorite(artist) ? "heart.fill" : "heart")
                            .frame(width: 28, height: 28)
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
            ArtworkView(title: artist.name, artworkKey: key, colors: theme.colorTokens, size: 200, cornerRadius: 100)
        } else if reps.count == 4 {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 4), GridItem(.flexible(), spacing: 4)], spacing: 4) {
                ForEach(reps) { album in
                    ArtworkView(title: album.title, artworkKey: album.artworkKey, colors: theme.colorTokens, size: 96, cornerRadius: 8)
                }
            }
            .frame(width: 196, height: 196)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 100, style: .continuous)
                    .fill(.quaternary)
                Text(String(artist.name.prefix(1)).uppercased())
                    .font(.system(size: 72, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 200, height: 200)
        }
    }
}
#endif
