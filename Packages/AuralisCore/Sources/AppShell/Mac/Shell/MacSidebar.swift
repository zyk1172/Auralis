#if os(macOS)
import Domain
import SwiftUI

/// 侧边栏：首页 + 资料库（可编辑显示/隐藏+排序）+ 播放列表（收藏歌曲 + 用户歌单内联）+ Auralis。
/// 系统 `.sidebar`；资料库项来自 MacSidebarPreferences。
struct MacSidebar: View {
    @ObservedObject var model: AuralisAppModel
    @ObservedObject var prefs: MacSidebarPreferences
    @Binding var selection: MacSidebarDestination?
    var onOpenPlaylist: (Playlist) -> Void = { _ in }

    @State private var isEditingLibrary = false
    @State private var isHoveringLibrary = false

    private var playlists: [Playlist] {
        model.catalog.playlists.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        List(selection: $selection) {
            Section {
                sidebarRow(.home)
            }
            Section {
                ForEach(prefs.enabledDestinations) { destination in
                    sidebarRow(destination)
                }
            } header: {
                libraryHeader
            }
            .popover(isPresented: $isEditingLibrary, arrowEdge: .trailing) {
                MacSidebarLibraryEditor(prefs: prefs)
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

    private var libraryHeader: some View {
        HStack {
            Text("资料库")
            Spacer()
            if isHoveringLibrary || isEditingLibrary {
                Button("编辑") { isEditingLibrary = true }
                    .buttonStyle(.link)
                    .help("显示或隐藏资料库项目、拖动排序")
                    .accessibilityLabel("编辑资料库")
            }
        }
        .onHover { isHoveringLibrary = $0 }
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
