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
                    ContentUnavailableView(String(localized: "歌单为空", bundle: .module), systemImage: "music.note.list",
                                           description: Text(String(localized: "这个歌单还没有歌曲。", bundle: .module)))
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
        .confirmationDialog(
            String(localized: "删除歌单「\(playlist.name)」？", bundle: .module),
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button(String(localized: "删除歌单", bundle: .module), role: .destructive) {
                Task { _ = await model.deletePlaylist(id: playlist.id) }
            }
            Button(String(localized: "取消", bundle: .module), role: .cancel) {}
        } message: {
            Text(String(localized: "只会删除歌单本身，不会删除其中的歌曲。", bundle: .module))
        }
    }

    private var hero: some View {
        HStack(alignment: .center, spacing: 24) {
            MacPlaylistArtwork(
                playlist: playlist,
                artworkKeys: MacPlaylistArtwork.artworkKeys(playlist: playlist, model: model),
                theme: theme,
                size: 200
            )
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
                    Text(String(localized: "\(tracks.count) 首 · \(MacFormat.durationSum(tracks))", bundle: .module))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    Button {
                        model.playQueue(tracks)
                    } label: {
                        Label(String(localized: "播放", bundle: .module), systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    Button {
                        model.playShuffledQueue(tracks)
                    } label: {
                        Label(String(localized: "随机播放", bundle: .module), systemImage: "shuffle")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    Menu {
                        Button(String(localized: "下载歌单", bundle: .module)) { model.downloadAll(tracks) }
                        Button(String(localized: "添加到队列", bundle: .module)) {
                            for track in tracks {
                                model.addToQueue(globalID: GlobalID(serverID: track.serverID, remoteID: track.id.rawValue))
                            }
                        }
                        Button(String(localized: "删除歌单", bundle: .module), role: .destructive) { isConfirmingDelete = true }
                    } label: {
                        Image(systemName: "ellipsis")
                            .frame(width: 28, height: 28)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help(String(localized: "更多操作", bundle: .module))
                }
            }
            Spacer()
        }
        .padding(.top, 20)
    }
}
#endif
