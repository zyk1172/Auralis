#if os(macOS)
import Domain

import DesignSystem
import LocalCatalog
import SwiftUI
import ThemeEngine

/// Apple Music 式详情页曲目行（不嵌套 Table）。
/// 整个详情页是一个 ScrollView + LazyVStack；行内 hover 显示 Play / More。
struct MacDetailTrackRow: View {
    let track: Track
    @ObservedObject var model: AuralisAppModel
    let theme: BuiltInTheme
    var number: Int? = nil
    var showArtist = false
    var showAlbum = false
    var onNavigate: (MacNavigationTarget) -> Void = { _ in }

    @State private var isHovering = false

    private var isCurrent: Bool {
        model.currentTrack.serverID == track.serverID && model.currentTrack.id == track.id
    }

    var body: some View {
        HStack(spacing: 10) {
            leading
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    if isCurrent {
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(theme.colorTokens.accent.color)
                            .accessibilityLabel("正在播放")
                    }
                    Text(track.title)
                        .font(.system(size: 13, weight: isCurrent ? .semibold : .regular))
                        .foregroundStyle(isCurrent ? theme.colorTokens.accent.color : Color.primary)
                        .lineLimit(1)
                }
                if showArtist || showAlbum {
                    HStack(spacing: 6) {
                        if showArtist {
                            Text(track.artistName)
                        }
                        if showAlbum {
                            Text(track.albumTitle)
                        }
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            if model.isDownloaded(track) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("已下载")
            }
            Text(MacFormat.time(track.duration))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 44, alignment: .trailing)
            Button {
                model.toggleFavorite(track)
            } label: {
                Image(systemName: track.isFavorite ? "heart.fill" : "heart")
                    .font(.system(size: 12))
                    .foregroundStyle(track.isFavorite ? theme.colorTokens.accent.color : Color.secondary.opacity(0.55))
            }
            .buttonStyle(.plain)
            .help(track.isFavorite ? "取消收藏" : "收藏")
            .accessibilityLabel(track.isFavorite ? "取消收藏" : "收藏")
            .frame(width: 22)

            if isHovering || !moreActions.isEmpty {
                Menu {
                    ForEach(moreActions) { action in
                        Button {
                            action.action()
                        } label: {
                            Label(action.title, systemImage: action.systemImage ?? "circle")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 12))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .opacity(isHovering ? 1 : 0.4)
                .help("更多操作")
                .accessibilityLabel("更多操作")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .contextMenu {
            macTrackMenuContent(track: track, model: model, onNavigate: onNavigate)
        }
        .onTapGesture(count: 2) {
            model.selectAndPlay(track)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(track.title)，\(track.artistName)，\(MacFormat.time(track.duration))")
    }

    @ViewBuilder
    private var leading: some View {
        if isHovering {
            Button {
                model.selectAndPlay(track)
            } label: {
                Image(systemName: "play.fill")
                    .font(.system(size: 11))
                    .frame(width: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("播放")
            .accessibilityLabel("播放")
        } else if let number {
            Text("\(number)")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 22, alignment: .trailing)
        } else {
            Color.clear.frame(width: 22)
        }
    }

    private var moreActions: [MacMenuAction] {
        let gid = GlobalID(serverID: track.serverID, remoteID: track.id.rawValue)
        let isDisliked = model.isDisliked(track)
        let isDownloaded = model.isDownloaded(track)
        return [
            MacMenuAction(title: "下一首播放", systemImage: "text.badge.plus") { model.playNext(globalID: gid) },
            MacMenuAction(title: "加入队列", systemImage: "text.badge.plus") { model.addToQueue(globalID: gid) },
            MacMenuAction(title: isDisliked ? "取消不喜欢" : "不喜欢", systemImage: "heart.slash") {
                model.setDisliked(track, value: !isDisliked, source: "user")
            },
            MacMenuAction(title: isDownloaded ? "删除下载" : "下载", systemImage: "arrow.down.circle") {
                if isDownloaded { model.removeDownload(track) } else { model.download(track) }
            },
            MacMenuAction(title: "歌曲信息", systemImage: "info.circle") {
                NotificationCenter.default.post(name: MacCommand.showTrackInformation, object: track)
            }
        ]
    }
}

/// 详情页曲目列表：VStack + 可选 Disc 分组头。
struct MacDetailTrackList: View {
    let tracks: [Track]
    @ObservedObject var model: AuralisAppModel
    let theme: BuiltInTheme
    var showArtist = false
    var showAlbum = false
    var numberText: (Track) -> Int? = { _ in nil }
    var onNavigate: (MacNavigationTarget) -> Void = { _ in }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                MacDetailTrackRow(
                    track: track,
                    model: model,
                    theme: theme,
                    number: numberText(track),
                    showArtist: showArtist,
                    showAlbum: showAlbum,
                    onNavigate: onNavigate
                )
                if index < tracks.count - 1 {
                    Divider().padding(.leading, 46)
                }
            }
        }
    }
}
#endif
