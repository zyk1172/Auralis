#if os(macOS)
import Domain
import SwiftUI

/// Apple Music 式侧边栏：浏览 / 资料库 / 播放列表 / Auralis。
/// 系统 `.sidebar`，不手工涂背景；真实播放列表直接内联，可折叠由系统滚动处理。
struct MacSidebar: View {
    @ObservedObject var model: AuralisAppModel
    @Binding var selection: MacRoute?

    private var playlists: [Playlist] {
        model.catalog.playlists.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        List(selection: $selection) {
            Section("浏览") {
                sidebarRow(.home)
                sidebarRow(.recentlyPlayed)
                sidebarRow(.recentlyAdded)
            }
            Section("资料库") {
                sidebarRow(.songs)
                sidebarRow(.albums)
                sidebarRow(.artists)
                sidebarRow(.genres)
                sidebarRow(.favorites)
                sidebarRow(.disliked)
                sidebarRow(.downloads)
            }
            Section("播放列表") {
                ForEach(playlists) { playlist in
                    sidebarRow(.playlist(playlist))
                }
            }
            Section("Auralis") {
                sidebarRow(.categories)
                sidebarRow(.assistant)
                sidebarRow(.server)
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: MacLayout.sidebarMin, ideal: MacLayout.sidebarIdeal, max: MacLayout.sidebarMax)
    }

    private func sidebarRow(_ item: MacRoute) -> some View {
        Label(item.title, systemImage: item.symbol)
            .tag(item)
    }
}
#endif
