import Foundation

/// 「正在播放」小组件的 Widget kind：App（LiveActivityManager 主动 reload）
/// 与 Widget Extension（StaticConfiguration）共用同一字符串，避免两处散落。
public enum AuralisNowPlayingWidgetKind {
    public static let kind = "AuralisNowPlaying"
}

/// Live Activity（灵动岛 / 锁屏实时活动）的属性模型。
/// App 与 Widget Extension 共用（通过 AuralisCore 共享），仅含必要标识与展示字段，
/// 不含服务器地址、凭据或文件路径。
public struct PlaybackActivityAttributes: Codable, Hashable, Sendable {
    /// 活动实例标识（按曲目生成，用于更新/结束对应活动）。
    public var activityID: String

    public init(activityID: String) {
        self.activityID = activityID
    }

    /// 动态内容：随播放进度/状态更新。
    public struct ContentState: Codable, Hashable, Sendable {
        public var title: String
        public var artist: String
        public var album: String
        public var artworkKey: String?
        public var serverID: String?
        public var trackID: String
        public var duration: Double
        public var position: Double
        public var isPlaying: Bool

        public init(
            title: String,
            artist: String,
            album: String,
            artworkKey: String?,
            serverID: String?,
            trackID: String,
            duration: Double,
            position: Double,
            isPlaying: Bool
        ) {
            self.title = title
            self.artist = artist
            self.album = album
            self.artworkKey = artworkKey
            self.serverID = serverID
            self.trackID = trackID
            self.duration = duration
            self.position = position
            self.isPlaying = isPlaying
        }
    }
}

#if os(iOS)
import ActivityKit

/// iOS 上把属性模型声明为 Live Activity 属性（ActivityKit 要求；macOS 上 ActivityAttributes 不可用）。
extension PlaybackActivityAttributes: ActivityAttributes {}
#endif