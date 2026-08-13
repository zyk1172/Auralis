#if os(macOS)
import SwiftUI
import ThemeEngine
import Domain
import LocalCatalog

/// 下载页：已离线歌曲 Table + 缓存用量（维护性质页面，标准 Table/Form 视觉）。
struct MacMusicDownloadsView: View {
    @ObservedObject var model: AuralisAppModel
    let theme: BuiltInTheme
    @Binding var selection: Set<GlobalID>
    var onNavigate: (MacNavigationTarget) -> Void = { _ in }

    private var tracks: [Track] {
        model.catalog.tracks.filter { model.isDownloaded($0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            if tracks.isEmpty {
                ContentUnavailableView("暂无下载", systemImage: "arrow.down.circle", description: Text("右键歌曲选择「下载」后可离线播放。"))
            } else {
                MacSongTable(
                    tracks: tracks,
                    selection: $selection,
                    model: model,
                    theme: theme,
                    onNavigate: onNavigate,
                    showGenreColumn: false
                )
            }
        }
        .navigationTitle("下载")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.playShuffledQueue(tracks)
                } label: {
                    Label("随机播放", systemImage: "shuffle")
                }
                .disabled(tracks.isEmpty)
            }
        }
    }
}
#endif
