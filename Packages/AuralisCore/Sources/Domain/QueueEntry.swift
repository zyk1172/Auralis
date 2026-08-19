import Foundation

/// 播放队列项（R05）：歌曲身份（Track）与队列项身份（UUID）分离。
///
/// 同一首歌可以在队列中出现多次，每次都是独立的队列项（对应 OpenSubsonic
/// `indexBasedQueue` 语义：队列按 index 定位，当前曲目由 index 表示）。
/// SwiftUI 列表 / ForEach 必须用 `id`（UUID）作为身份，不能用 `track.id`——
/// 否则重复歌曲会在渲染期因重复 ID 崩溃。
public struct QueueEntry: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public var track: Track

    public init(id: UUID = UUID(), track: Track) {
        self.id = id
        self.track = track
    }
}
