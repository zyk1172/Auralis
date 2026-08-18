#if os(macOS)
import Domain
import LocalCatalog
import SwiftUI
import ThemeEngine

/// Genre Detail：标题 + 歌曲数 + Play/Shuffle + 曲目行 + 专辑网格。
/// Album 过滤使用 (serverID, albumID) 双键，避免跨服务器 albumID 串库。
struct MacGenreView: View {
    let genre: Genre
    @ObservedObject var model: AuralisAppModel
    let theme: BuiltInTheme
    @Binding var selection: Set<GlobalID>
    var onNavigate: (MacNavigationTarget) -> Void = { _ in }

    private var tracks: [Track] { model.tracks(for: genre) }
    private var albums: [Album] { MacLibraryQuery.genreAlbums(genre, model: model) }

    private let columns = [GridItem(.adaptive(minimum: 140, maximum: 180), spacing: MacUIVisualTokens.Artwork.gridGap)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                if !tracks.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("歌曲")
                            .font(.system(size: MacUIVisualTokens.Typography.sectionTitle, weight: .bold))
                        MacDetailTrackList(
                            tracks: tracks,
                            model: model,
                            theme: theme,
                            showArtist: true,
                            showAlbum: true,
                            onNavigate: onNavigate
                        )
                    }
                }
                if !albums.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("专辑")
                            .font(.system(size: MacUIVisualTokens.Typography.sectionTitle, weight: .bold))
                        LazyVGrid(columns: columns, spacing: 24) {
                            ForEach(albums) { album in
                                MacAlbumTile(
                                    album: album,
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
        .navigationTitle(genre.name)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                Text(genre.name)
                    .font(.system(size: 30, weight: .bold, design: .default))
                Text("\(tracks.count) 首歌曲 · \(albums.count) 张专辑")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Button {
                        model.playQueue(tracks)
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
                    Menu {
                        Button("下载全部") { model.downloadAll(tracks) }
                    } label: {
                        Image(systemName: "ellipsis")
                            .frame(width: 28, height: 28)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("更多操作")
                }
            }
            Spacer()
        }
        .padding(.top, 20)
    }
}

/// (serverID, albumID) 双键身份，供跨服务器 Album 过滤。
struct AlbumRouteIdentity: Hashable {
    let serverID: ServerID
    let remoteID: String
}
#endif
