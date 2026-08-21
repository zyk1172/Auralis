#if os(macOS)
import Domain
import LocalCatalog
import SwiftUI

/// 统一 Mac 单曲右键菜单内容：播放 / 导航 / 私人状态 / 文件 / 资料，按 Divider 分组。
/// 返回可直接放进 `.contextMenu {}` 的菜单项视图。
@MainActor
func macTrackMenuContent(
    track: Track,
    model: AuralisAppModel,
    onNavigate: @escaping (MacNavigationTarget) -> Void
) -> some View {
    let gid = GlobalID(serverID: track.serverID, remoteID: track.id.rawValue)
    let isFavorite = model.catalog.tracks.first(where: { $0.serverID == track.serverID && $0.id == track.id })?.isFavorite ?? track.isFavorite
    let isDisliked = model.isDisliked(track)
    let isDownloaded = model.isDownloaded(track)
    let album = model.catalog.albums.first(where: { $0.id == track.albumID && $0.serverID == track.serverID })
    let artist = model.catalog.artists.first(where: { $0.id == track.artistID && $0.serverID == track.serverID })
    let playlists = model.catalog.playlists.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

    return Group {
        Button(String(localized: "播放", bundle: .module)) { model.selectAndPlay(track) }
        Button(String(localized: "下一首播放", bundle: .module)) { model.playNext(globalID: gid) }
        Button(String(localized: "加入队列", bundle: .module)) { model.addToQueue(globalID: gid) }

        Divider()

        Menu(String(localized: "添加到歌单", bundle: .module)) {
            if playlists.isEmpty {
                Text(String(localized: "暂无歌单", bundle: .module))
            }
            ForEach(playlists) { playlist in
                Button(playlist.name) {
                    Task { _ = await model.addToPlaylist(playlist, track: track) }
                }
            }
        }

        if let album {
            Button(String(localized: "前往专辑", bundle: .module)) { onNavigate(.album(album)) }
        }
        if let artist {
            Button(String(localized: "前往艺术家", bundle: .module)) { onNavigate(.artist(artist)) }
        }

        Divider()

        Button(isFavorite ? String(localized: "取消收藏", bundle: .module) : String(localized: "收藏", bundle: .module)) { model.toggleFavorite(track) }
        Button(isDisliked ? String(localized: "取消不喜欢", bundle: .module) : String(localized: "不喜欢", bundle: .module)) {
            model.setDisliked(track, value: !isDisliked, source: "user")
        }

        Divider()

        Button(isDownloaded ? String(localized: "删除下载", bundle: .module) : String(localized: "下载", bundle: .module)) {
            if isDownloaded {
                model.removeDownload(track)
            } else {
                model.download(track)
            }
        }

        Divider()

        Button(String(localized: "歌曲鉴赏", bundle: .module)) {
            NotificationCenter.default.post(name: MacCommand.songAppreciation, object: track)
        }
        Button(String(localized: "歌曲信息", bundle: .module)) {
            NotificationCenter.default.post(name: MacCommand.showTrackInformation, object: track)
        }
    }
}

extension View {
    func macTrackContextMenu(
        track: Track,
        model: AuralisAppModel,
        onNavigate: @escaping (MacNavigationTarget) -> Void
    ) -> some View {
        contextMenu {
            macTrackMenuContent(track: track, model: model, onNavigate: onNavigate)
        }
    }
}
#endif
