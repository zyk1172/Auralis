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
    /// 播放上下文（所在专辑/歌单/流派/艺术家详情页的完整曲目列表）：
    /// 双击或 hover 播放时先把整列写入队列，与 iOS 列表点击同一机制。
    /// 为空时退化为只播放当前这首。
    var contextTracks: [Track] = []

    @ObservedObject private var playbackStore: PlaybackStore

    init(
        track: Track,
        model: AuralisAppModel,
        theme: BuiltInTheme,
        number: Int? = nil,
        showArtist: Bool = false,
        showAlbum: Bool = false,
        onNavigate: @escaping (MacNavigationTarget) -> Void = { _ in },
        contextTracks: [Track] = []
    ) {
        self.track = track
        self._model = ObservedObject(wrappedValue: model)
        self.theme = theme
        self.number = number
        self.showArtist = showArtist
        self.showAlbum = showAlbum
        self.onNavigate = onNavigate
        self.contextTracks = contextTracks
        self._playbackStore = ObservedObject(wrappedValue: model.playbackStore)
    }

    @State private var isHovering = false

    private var isCurrent: Bool {
        playbackStore.currentTrack.serverID == track.serverID && playbackStore.currentTrack.id == track.id
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
                            .accessibilityLabel(String(localized: "正在播放", bundle: .module))
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
                    .accessibilityLabel(String(localized: "已下载", bundle: .module))
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
            .accessibilityLabel(track.isFavorite ? String(localized: "取消收藏", bundle: .module) : String(localized: "收藏", bundle: .module))
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
                .accessibilityLabel(String(localized: "更多操作", bundle: .module))
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
            model.playTrack(track, in: contextTracks)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(track.title)，\(track.artistName)，\(MacFormat.time(track.duration))")
    }

    @ViewBuilder
    private var leading: some View {
        if isHovering {
            Button {
                model.playTrack(track, in: contextTracks)
            } label: {
                Image(systemName: "play.fill")
                    .font(.system(size: 11))
                    .frame(width: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("播放")
            .accessibilityLabel(String(localized: "播放", bundle: .module))
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

/// 详情页曲目列表：真正的 LazyVStack。流派或大型歌单即使有数千首歌，
/// 也只创建当前视口附近的 Row，不在打开详情时一次实例化全部 SwiftUI 子树。
struct MacDetailTrackList: View {
    let tracks: [Track]
    @ObservedObject var model: AuralisAppModel
    let theme: BuiltInTheme
    var showArtist = false
    var showAlbum = false
    var numberText: (Track) -> Int? = { _ in nil }
    var onNavigate: (MacNavigationTarget) -> Void = { _ in }

    var body: some View {
        LazyVStack(spacing: 0) {
            ForEach(tracks, id: \.macGlobalID) { track in
                MacDetailTrackRow(
                    track: track,
                    model: model,
                    theme: theme,
                    number: numberText(track),
                    showArtist: showArtist,
                    showAlbum: showAlbum,
                    onNavigate: onNavigate,
                    contextTracks: tracks
                )
                // 最后一个 row 不画分隔线，避免列表底部多出一条；无需 enumerate。
                if track.macGlobalID != tracks.last?.macGlobalID {
                    Divider().padding(.leading, 46)
                }
            }
        }
    }
}
#endif