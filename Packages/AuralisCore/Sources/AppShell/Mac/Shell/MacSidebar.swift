#if os(macOS)
import Domain
import SwiftUI

/// 侧边栏：一级目的地 + 播放列表（含「收藏歌曲」智能集合）内联。
/// 使用系统 `.sidebar` 与系统 accent；不手工涂色。
struct MacSidebar: View {
    @ObservedObject var model: AuralisAppModel
    @Binding var selection: MacSidebarDestination?
    var onOpenPlaylist: (Playlist) -> Void = { _ in }

    private var playlists: [Playlist] {
        model.catalog.playlists.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        List(selection: $selection) {
            Section {
                sidebarRow(.home)
            }
            Section("资料库") {
                sidebarRow(.recentlyAdded)
                sidebarRow(.recentlyPlayed)
                sidebarRow(.artists)
                sidebarRow(.albums)
                sidebarRow(.songs)
                sidebarRow(.genres)
                sidebarRow(.downloads)
            }
            Section("播放列表") {
                sidebarRow(.favorites)
                ForEach(playlists) { playlist in
                    sidebarRow(playlist)
                }
            }
            Section("Auralis") {
                sidebarRow(.categories)
                sidebarRow(.disliked)
                sidebarRow(.assistant)
                sidebarRow(.server)
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 300)
    }

    private func sidebarRow(_ item: MacSidebarDestination) -> some View {
        Label(item.title, systemImage: item.symbol)
            .tag(item)
    }

    private func sidebarRow(_ playlist: Playlist) -> some View {
        Button {
            onOpenPlaylist(playlist)
        } label: {
            Label(playlist.name, systemImage: "music.note.list")
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("播放") {
                let tracks = MacLibraryQuery.playlistTracks(playlist, model: model)
                if !tracks.isEmpty { model.playQueue(tracks) }
            }
            Button("随机播放") {
                let tracks = MacLibraryQuery.playlistTracks(playlist, model: model)
                if !tracks.isEmpty { model.playShuffledQueue(tracks) }
            }
            Divider()
            Button("删除歌单", role: .destructive) {
                Task { _ = await model.deletePlaylist(id: playlist.id) }
            }
        }
    }
}
#endif
