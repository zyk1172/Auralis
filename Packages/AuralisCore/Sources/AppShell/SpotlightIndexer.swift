import Domain
import Foundation
import LocalCatalog
#if os(iOS)
import CoreSpotlight
import UniformTypeIdentifiers
#endif

/// Spotlight 索引：把本地持久化资料库的歌曲/专辑/艺术家/歌单登记到系统搜索。
/// 仅索引名称与必要标识（不包含服务器地址、凭据或文件路径）。
/// 打开时通过 `auralis://track/<serverID>:<trackID>` 等标识回跳 App。
@MainActor
public enum SpotlightIndexer {
    /// 重新登记整个资料库（幂等：同 uniqueIdentifier 会覆盖）。
    /// `dislikedTrackIDs` 用于排除「不喜欢」的歌曲：Spotlight 是发现面，
    /// 不应把用户明确排斥的歌曲推回搜索（P2-2；显式回跳播放仍不受限）。
    public static func reindex(
        artists: [Artist],
        albums: [Album],
        tracks: [Track],
        playlists: [Playlist],
        dislikedTrackIDs: Set<GlobalID> = []
    ) {
        #if os(iOS)
        guard CSSearchableIndex.isIndexingAvailable() else { return }
        var items: [CSSearchableItem] = []

        for track in tracks where !dislikedTrackIDs.contains(
            GlobalID(serverID: track.serverID, remoteID: track.id.rawValue)
        ) {
            let attribute = CSSearchableItemAttributeSet(contentType: .audio)
            attribute.title = track.title
            attribute.contentDescription = "\(track.artistName) · \(track.albumTitle)"
            attribute.keywords = [track.title, track.artistName, track.albumTitle]
            items.append(CSSearchableItem(
                uniqueIdentifier: "auralis://track/\(track.serverID.rawValue):\(track.id.rawValue)",
                domainIdentifier: "com.auralis.player.music",
                attributeSet: attribute
            ))
        }
        for album in albums {
            let attribute = CSSearchableItemAttributeSet(contentType: .item)
            attribute.title = album.title
            attribute.artist = album.artistName
            attribute.contentDescription = "专辑 · \(album.artistName)"
            attribute.keywords = [album.title, album.artistName]
            items.append(CSSearchableItem(
                uniqueIdentifier: "auralis://album/\(album.serverID.rawValue):\(album.id.rawValue)",
                domainIdentifier: "com.auralis.player.music",
                attributeSet: attribute
            ))
        }
        for artist in artists {
            let attribute = CSSearchableItemAttributeSet(contentType: .item)
            attribute.title = artist.name
            attribute.contentDescription = "艺术家 · \(artist.albumCount) 张专辑"
            attribute.keywords = [artist.name]
            items.append(CSSearchableItem(
                uniqueIdentifier: "auralis://artist/\(artist.serverID.rawValue):\(artist.id.rawValue)",
                domainIdentifier: "com.auralis.player.music",
                attributeSet: attribute
            ))
        }
        for playlist in playlists {
            let attribute = CSSearchableItemAttributeSet(contentType: .item)
            attribute.title = playlist.name
            attribute.contentDescription = "歌单 · \(playlist.trackIDs.count) 首"
            attribute.keywords = [playlist.name]
            items.append(CSSearchableItem(
                uniqueIdentifier: "auralis://playlist/\(playlist.serverID.rawValue):\(playlist.id.rawValue)",
                domainIdentifier: "com.auralis.player.music",
                attributeSet: attribute
            ))
        }

        CSSearchableIndex.default().indexSearchableItems(items) { _ in }
        #endif
    }

    /// 清除全部 Spotlight 条目（移除服务器或退出时调用）。
    public static func clearAll() {
        #if os(iOS)
        CSSearchableIndex.default().deleteAllSearchableItems { _ in }
        #endif
    }
}
