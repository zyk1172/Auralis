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
    var showsDislike = false

    var body: some View {
        VStack(spacing: 0) {
            if tracks.isEmpty {
                ContentUnavailableView("暂无内容", systemImage: "music.note", description: Text("这里还没有歌曲。"))
            } else {
                MacSongTable(
                    tracks: tracks,
                    selection: $selection,
                    model: model,
                    theme: theme,
                    onNavigate: onNavigate,
                    numberText: { _ in nil },
                    showAlbumColumn: true,
                    showYearColumn: true,
                    showGenreColumn: false,
                    showArtwork: true
                )
            }
        }
        .navigationTitle(title)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    model.playShuffledQueue(tracks)
                } label: {
                    Label("随机播放", systemImage: "shuffle")
                }
                .disabled(tracks.isEmpty)
                Button {
                    model.playQueue(tracks)
                } label: {
                    Label("播放", systemImage: "play.fill")
                }
                .disabled(tracks.isEmpty)
            }
        }
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
                ContentUnavailableView("没有不喜欢的歌曲", systemImage: "heart.slash", description: Text("右键歌曲可选择「不喜欢」。"))
            } else {
                MacSongTable(
                    tracks: tracks,
                    selection: $selection,
                    model: model,
                    theme: theme,
                    onNavigate: onNavigate,
                    numberText: { _ in nil },
                    showGenreColumn: false,
                )
            }
        }
        .navigationTitle("不喜欢")
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
