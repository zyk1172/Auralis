#if os(macOS)
import SwiftUI
import ThemeEngine
import Domain
import LocalCatalog

/// Genre Detail：大标题 + 歌曲数 + Play/Shuffle + Songs + Albums。保持简单，不做彩色卡片墙。
struct MacGenreView: View {
    let genre: Genre
    @ObservedObject var model: AuralisAppModel
    let theme: BuiltInTheme
    @Binding var selection: Set<GlobalID>
    var onNavigate: (MacRoute) -> Void = { _ in }

    private var tracks: [Track] { model.tracks(for: genre) }
    private var albums: [Album] {
        let albumIDs = Set(tracks.map(\.albumID))
        return model.catalog.albums.filter { albumIDs.contains($0.id) }
    }

    private let columns = [GridItem(.adaptive(minimum: 140, maximum: 180), spacing: MacLayout.artworkGridGap)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .center, spacing: 20) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(genre.name)
                            .font(.system(size: 30, weight: .bold, design: .default))
                        Text("\(tracks.count) 首歌曲 · \(albums.count) 张专辑")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 12) {
                            MacPrimaryButton(title: "播放", systemImage: "play.fill") {
                                model.playQueue(tracks)
                            }
                            MacPrimaryButton(title: "随机播放", systemImage: "shuffle", prominent: false) {
                                model.playShuffledQueue(tracks)
                            }
                        }
                    }
                    Spacer()
                }
                .padding(.top, 20)

                if !tracks.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("歌曲")
                            .font(.system(size: MacLayout.sectionTitleSize, weight: .bold))
                        MacSongTable(
                            tracks: tracks,
                            selection: $selection,
                            model: model,
                            theme: theme,
                            onNavigate: onNavigate,
                            showYearColumn: false,
                            showGenreColumn: false,
                            showFormatColumn: false,
                            showArtwork: false,
                            rowHeight: 34
                        )
                    }
                }

                if !albums.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("专辑")
                            .font(.system(size: MacLayout.sectionTitleSize, weight: .bold))
                        LazyVGrid(columns: columns, spacing: 24) {
                            ForEach(albums) { album in
                                MacArtworkCard(
                                    title: album.title,
                                    subtitle: album.artistName,
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
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .navigationTitle(genre.name)
    }
}
#endif
