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
    onNavigate: @escaping (MacRoute) -> Void
) -> some View {
    let gid = GlobalID(serverID: track.serverID, remoteID: track.id.rawValue)
    let isFavorite = model.catalog.tracks.first(where: { $0.serverID == track.serverID && $0.id == track.id })?.isFavorite ?? track.isFavorite
    let isDisliked = model.isDisliked(track)
    let isDownloaded = model.isDownloaded(track)
    let album = model.catalog.albums.first(where: { $0.id == track.albumID && $0.serverID == track.serverID })
    let artist = model.catalog.artists.first(where: { $0.id == track.artistID && $0.serverID == track.serverID })
    let playlists = model.catalog.playlists.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

    return Group {
        Button("播放") { model.selectAndPlay(track) }
        Button("下一首播放") { model.playNext(globalID: gid) }
        Button("加入队列") { model.addToQueue(globalID: gid) }

        Divider()

        Menu("添加到歌单") {
            if playlists.isEmpty {
                Text("暂无歌单")
            }
            ForEach(playlists) { playlist in
                Button(playlist.name) {
                    Task { _ = await model.addToPlaylist(playlist, track: track) }
                }
            }
        }

        if let album {
            Button("前往专辑") { onNavigate(.album(album)) }
        }
        if let artist {
            Button("前往艺术家") { onNavigate(.artist(artist)) }
        }

        Divider()

        Button(isFavorite ? "取消收藏" : "收藏") { model.toggleFavorite(track) }
        Button(isDisliked ? "取消不喜欢" : "不喜欢") {
            model.setDisliked(track, value: !isDisliked, source: "user")
        }

        Divider()

        Button(isDownloaded ? "删除下载" : "下载") {
            if isDownloaded {
                model.removeDownload(track)
            } else {
                model.download(track)
            }
        }

        Divider()

        Button("歌曲鉴赏") {
            NotificationCenter.default.post(name: MacCommand.songAppreciation, object: track)
        }
        Button("歌曲信息") {
            NotificationCenter.default.post(name: MacCommand.showTrackInformation, object: track)
        }
    }
}

extension View {
    func macTrackContextMenu(
        track: Track,
        model: AuralisAppModel,
        onNavigate: @escaping (MacRoute) -> Void
    ) -> some View {
        contextMenu {
            macTrackMenuContent(track: track, model: model, onNavigate: onNavigate)
        }
    }
}
#endif
