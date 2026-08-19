#if os(macOS)
import SwiftUI
import ThemeEngine
import Domain
import LocalCatalog

/// 通用曲目集合页（最近播放 / 最近添加 / 收藏歌曲 / 不喜欢）：
/// Apple Music 式标题 + 主操作 + 原生 Table。
struct MacTrackCollectionView: View {
    let title: String
    let tracks: [Track]
    @ObservedObject var model: AuralisAppModel
    let theme: BuiltInTheme
    @Binding var selection: Set<GlobalID>
    var onNavigate: (MacNavigationTarget) -> Void = { _ in }
    /// 行内容修订号：动态集合（最近播放/收藏等）在 catalogRevision 不变但内容变化时，
    /// 由调用方传入对应领域的 O(1) revision 驱动 Table 重建。
    var contentRevision: UInt64 = 0
    var showsDislike = false

    var body: some View {
        VStack(spacing: 0) {
            if tracks.isEmpty {
                ContentUnavailableView(String(localized: "暂无内容", bundle: .module), systemImage: "music.note", description: Text(String(localized: "这里还没有歌曲。", bundle: .module)))
            } else {
                MacSongTable(
                    tracks: tracks,
                    selection: $selection,
                    model: model,
                    theme: theme,
                    onNavigate: onNavigate,
                    contentRevision: contentRevision,
                    numberText: { _ in nil },
                    showAlbumColumn: true,
                    showYearColumn: true,
                    showGenreColumn: false,
                    showArtwork: true
                )
            }
        }
        .navigationTitle(title)
        // 顶部不留按钮：随机播放 / 播放按钮移除。
    }
}

/// 「不喜欢」Smart Collection：可双击播放、右键取消不喜欢，不隐藏歌曲。
struct MacDislikedView: View {
    @ObservedObject var model: AuralisAppModel
    let theme: BuiltInTheme
    @Binding var selection: Set<GlobalID>
    var onNavigate: (MacNavigationTarget) -> Void = { _ in }

    private var tracks: [Track] {
        model.dislikedTrackIDs.compactMap { model.track(for: $0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            if tracks.isEmpty {
                ContentUnavailableView(String(localized: "没有不喜欢的歌曲", bundle: .module), systemImage: "heart.slash", description: Text(String(localized: "右键歌曲可选择「不喜欢」。", bundle: .module)))
            } else {
                MacSongTable(
                    tracks: tracks,
                    selection: $selection,
                    model: model,
                    theme: theme,
                    onNavigate: onNavigate,
                    contentRevision: model.dislikedRevision,
                    numberText: { _ in nil },
                    showGenreColumn: false,
                )
            }
        }
        .navigationTitle(String(localized: "不喜欢", bundle: .module))
        // 顶部不留按钮：随机播放按钮移除。
    }
}
#endif