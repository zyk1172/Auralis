#if os(macOS)
import SwiftUI
import ThemeEngine
import Domain
import LocalCatalog

/// Apple Music 式 Playlist Detail：大封面（真实歌单封面或前 4 首 2×2 mosaic）
/// + 名称/描述/曲目数/时长 + Play/Shuffle/More + Song Table。
struct MacPlaylistView: View {
    let playlist: Playlist
    @ObservedObject var model: AuralisAppModel
    let theme: BuiltInTheme
    @Binding var selection: Set<GlobalID>
    var onNavigate: (MacRoute) -> Void = { _ in }

    private var tracks: [Track] { MacLibraryQuery.playlistTracks(playlist, model: model) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                hero
                Divider()
                MacSongTable(
                    tracks: tracks,
                    selection: $selection,
                    model: model,
                    theme: theme,
                    onNavigate: onNavigate,
                    numberText: { _ in nil },
                    showGenreColumn: false,
                    showFormatColumn: false,
                    showArtwork: true,
                    rowHeight: 40
                )
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .navigationTitle(playlist.name)
    }

    private var hero: some View {
        HStack(alignment: .center, spacing: 24) {
            artwork
                .frame(width: 220, height: 220)
            VStack(alignment: .leading, spacing: 10) {
                Text(playlist.name)
                    .font(.system(size: 30, weight: .bold, design: .default))
                if let comment = playlist.comment, !comment.isEmpty {
                    Text(comment)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Text("\(tracks.count) 首 · \(MacFormat.durationSum(tracks))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    MacPrimaryButton(title: "播放", systemImage: "play.fill") {
                        model.playQueue(tracks)
                    }
                    MacPrimaryButton(title: "随机播放", systemImage: "shuffle", prominent: false) {
                        model.playShuffledQueue(tracks)
                    }
                    Menu {
                        Button("添加到队列") {
                            for track in tracks { model.addToQueue(globalID: GlobalID(serverID: track.serverID, remoteID: track.id.rawValue)) }
                        }
                        Button("删除歌单", role: .destructive) {
                            Task { _ = await model.deletePlaylist(id: playlist.id) }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .frame(width: 32, height: 32)
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

    @ViewBuilder
    private var artwork: some View {
        let reps = Array(tracks.prefix(4))
        if reps.isEmpty {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.quaternary)
                Image(systemName: "music.note.list")
                    .font(.system(size: 64))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 220, height: 220)
        } else if reps.count == 4 {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 4), GridItem(.flexible(), spacing: 4)], spacing: 4) {
                ForEach(reps) { track in
                    ArtworkView(title: track.albumTitle, artworkKey: track.artworkKey, colors: theme.colorTokens, size: 106, cornerRadius: 8)
                }
            }
            .frame(width: 216, height: 216)
        } else {
            ArtworkView(title: playlist.name, artworkKey: reps.first?.artworkKey, colors: theme.colorTokens, size: 220, cornerRadius: 14)
        }
    }
}
#endif
