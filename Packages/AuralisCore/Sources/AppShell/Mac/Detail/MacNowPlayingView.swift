#if os(macOS)
import Domain
import LocalCatalog
import SwiftUI
import ThemeEngine

/// 普通「正在播放」：大封面 + 标题/艺术家/专辑 + 私人状态 + 简洁上下文。
/// 公开音乐资料 / 技术参数一律放在「歌曲信息」（Get Info）。
struct MacNowPlayingView: View {
    @ObservedObject var model: AuralisAppModel
    let theme: BuiltInTheme

    private var track: Track { model.currentTrack }

    var body: some View {
        HStack(alignment: .center, spacing: 40) {
            Spacer(minLength: 20)
            ArtworkView(
                title: track.albumTitle,
                artworkKey: track.artworkKey,
                colors: theme.colorTokens,
                size: 320,
                cornerRadius: 16
            )
            .shadow(color: .black.opacity(0.2), radius: 7, y: 3)

            VStack(alignment: .leading, spacing: 12) {
                Text(track.title)
                    .font(.system(size: 28, weight: .bold, design: .default))
                    .lineLimit(2)
                Text(track.artistName)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(theme.colorTokens.accent.color)
                Text(track.albumTitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    Button {
                        model.toggleFavorite(track)
                    } label: {
                        Label(track.isFavorite ? "取消收藏" : "收藏",
                              systemImage: track.isFavorite ? "heart.fill" : "heart")
                    }
                    .buttonStyle(.bordered)
                    Menu {
                        Button(model.isDisliked(track) ? "取消不喜欢" : "不喜欢") {
                            model.setDisliked(track, value: !model.isDisliked(track), source: "user")
                        }
                        Button("歌曲信息") {
                            NotificationCenter.default.post(name: MacCommand.showTrackInformation, object: track)
                        }
                        Button("歌词") {
                            NotificationCenter.default.post(name: MacCommand.toggleLyrics, object: nil)
                        }
                        Button("队列") {
                            NotificationCenter.default.post(name: MacCommand.toggleQueue, object: nil)
                        }
                    } label: {
                        Label("更多", systemImage: "ellipsis")
                    }
                    .buttonStyle(.bordered)
                }
            }
            Spacer(minLength: 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .navigationTitle("正在播放")
    }
}
#endif
