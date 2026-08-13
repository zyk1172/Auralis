#if os(macOS)
import Domain
import SwiftUI

/// 侧边栏（REFERENCE_A）：顶部 搜索/主页；资料库（可编辑显示/隐藏+排序）；
/// 播放列表 = 收藏歌曲 + 所有播放列表（不再把每个用户歌单铺进 Sidebar）；Auralis 扩展区。
struct MacSidebar: View {
    @ObservedObject var model: AuralisAppModel
    @ObservedObject var prefs: MacSidebarPreferences
    @Binding var selection: MacSidebarDestination?

    @State private var isEditingLibrary = false
    @State private var isHoveringLibrary = false

    var body: some View {
        List(selection: $selection) {
            Section {
                sidebarRow(.search)
                sidebarRow(.home)
            }
            Section {
                ForEach(prefs.enabledDestinations) { destination in
                    sidebarRow(destination)
                }
            } header: {
                libraryHeader
            }
            Section("播放列表") {
                sidebarRow(.favorites)
                sidebarRow(.playlists)
            }
            Section("Auralis") {
                sidebarRow(.categories)
                sidebarRow(.disliked)
                sidebarRow(.assistant)
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: MacUIVisualTokens.Sidebar.minWidth, ideal: MacUIVisualTokens.Sidebar.idealWidth, max: MacUIVisualTokens.Sidebar.maxWidth)
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
                    // Section header 不是稳定 popover 锚点。把 popover 直接挂在按钮上，
                    // 使这个编辑入口在资料库页面与所有窗口尺寸下都可点开。
                    .popover(isPresented: $isEditingLibrary, arrowEdge: .trailing) {
                        MacSidebarLibraryEditor(prefs: prefs)
                    }
            }
        }
        .onHover { isHoveringLibrary = $0 }
    }

    private func sidebarRow(_ item: MacSidebarDestination) -> some View {
        Label(item.title, systemImage: item.symbol)
            .tag(item)
    }
}
#endif
