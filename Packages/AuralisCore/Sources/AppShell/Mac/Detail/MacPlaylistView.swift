#if os(macOS)
import Domain
import LocalCatalog
import SwiftUI
import ThemeEngine

/// Playlist Detail：Hero（真实 mosaic 封面）+ 曲目行 + 删除确认。
struct MacPlaylistView: View {
    let playlist: Playlist
    @ObservedObject var model: AuralisAppModel
    let theme: BuiltInTheme
    @Binding var selection: Set<GlobalID>
    var onNavigate: (MacNavigationTarget) -> Void = { _ in }

    @State private var isConfirmingDelete = false

    private var tracks: [Track] { MacLibraryQuery.playlistTracks(playlist, model: model) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                hero
                Divider()
                if tracks.isEmpty {
                    ContentUnavailableView("歌单为空", systemImage: "music.note.list",
                                           description: Text("这个歌单还没有歌曲。"))
                } else {
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
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .navigationTitle(playlist.name)
        .confirmationDialog("删除歌单「\(playlist.name)」？", isPresented: $isConfirmingDelete, titleVisibility: .visible) {
            Button("删除歌单", role: .destructive) {
                Task { _ = await model.deletePlaylist(id: playlist.id) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只会删除歌单本身，不会删除其中的歌曲。")
        }
    }

    private var hero: some View {
        HStack(alignment: .center, spacing: 24) {
            MacPlaylistArtwork(playlist: playlist, model: model, theme: theme, size: 200)
                .frame(width: 200, height: 200)
            VStack(alignment: .leading, spacing: 10) {
                Text(playlist.name)
                    .font(.system(size: 30, weight: .bold, design: .default))
                if let comment = playlist.comment, !comment.isEmpty {
                    Text(comment)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if !tracks.isEmpty {
                    Text("\(tracks.count) 首 · \(MacFormat.durationSum(tracks))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
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
                        Button("下载歌单") { model.downloadAll(tracks) }
                        Button("添加到队列") {
                            for track in tracks {
                                model.addToQueue(globalID: GlobalID(serverID: track.serverID, remoteID: track.id.rawValue))
                            }
                        }
                        Button("删除歌单", role: .destructive) { isConfirmingDelete = true }
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
#endif
