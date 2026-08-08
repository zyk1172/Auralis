import Domain
import Foundation
import LocalCatalog

/// Agent 回传给 UI 的结构化消息种类。
public enum AgentMessage: Sendable {
    /// 纯文本说明。
    case text(String)
    /// 单曲卡片列表（每张含真实 GlobalTrackID，点击直接本地播放）。
    case trackCards([TrackCard])
    /// 专辑卡片列表。
    case albumCards([AlbumCard])
    /// 歌单提案（一组曲目 + 命名建议）。
    case playlistProposal(name: String, tracks: [TrackCard])
    /// 即将执行的操作预览（修改型操作在执行前展示）。
    case actionPreview(title: String, detail: String)
    /// 工具执行进度（透明展示规划过程）。
    case toolProgress(step: String)
    /// 错误。
    case error(String)
    /// 需要用户确认的操作。
    case confirmation(PendingConfirmation)
}

extension AgentMessage: Codable {
    private enum Kind: String, Codable {
        case text, trackCards, albumCards, playlistProposal, actionPreview, toolProgress, error, confirmation
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .text(value):
            try container.encode(Kind.text, forKey: .type)
            try container.encode(value, forKey: .value)
        case let .trackCards(value):
            try container.encode(Kind.trackCards, forKey: .type)
            try container.encode(value, forKey: .value)
        case let .albumCards(value):
            try container.encode(Kind.albumCards, forKey: .type)
            try container.encode(value, forKey: .value)
        case let .playlistProposal(name, tracks):
            try container.encode(Kind.playlistProposal, forKey: .type)
            try container.encode(name, forKey: .name)
            try container.encode(tracks, forKey: .value)
        case let .actionPreview(title, detail):
            try container.encode(Kind.actionPreview, forKey: .type)
            try container.encode(title, forKey: .title)
            try container.encode(detail, forKey: .detail)
        case let .toolProgress(step):
            try container.encode(Kind.toolProgress, forKey: .type)
            try container.encode(step, forKey: .value)
        case let .error(value):
            try container.encode(Kind.error, forKey: .type)
            try container.encode(value, forKey: .value)
        case let .confirmation(value):
            try container.encode(Kind.confirmation, forKey: .type)
            try container.encode(value, forKey: .value)
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .type)
        switch kind {
        case .text: self = .text(try container.decode(String.self, forKey: .value))
        case .trackCards: self = .trackCards(try container.decode([TrackCard].self, forKey: .value))
        case .albumCards: self = .albumCards(try container.decode([AlbumCard].self, forKey: .value))
        case .playlistProposal:
            self = .playlistProposal(
                name: try container.decode(String.self, forKey: .name),
                tracks: try container.decode([TrackCard].self, forKey: .value)
            )
        case .actionPreview:
            self = .actionPreview(
                title: try container.decode(String.self, forKey: .title),
                detail: try container.decode(String.self, forKey: .detail)
            )
        case .toolProgress: self = .toolProgress(step: try container.decode(String.self, forKey: .value))
        case .error: self = .error(try container.decode(String.self, forKey: .value))
        case .confirmation: self = .confirmation(try container.decode(PendingConfirmation.self, forKey: .value))
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type, value, name, title, detail
    }
}

/// 单曲卡片：包含可直接播放的真实全局 ID 与展示信息。
public struct TrackCard: Codable, Sendable, Identifiable, Hashable {
    public var id: GlobalID { globalID }
    public let globalID: GlobalID
    public let title: String
    public let artistName: String
    public let albumTitle: String
    public let duration: TimeInterval
    public let isFavorite: Bool

    public init(globalID: GlobalID, title: String, artistName: String, albumTitle: String, duration: TimeInterval, isFavorite: Bool) {
        self.globalID = globalID
        self.title = title
        self.artistName = artistName
        self.albumTitle = albumTitle
        self.duration = duration
        self.isFavorite = isFavorite
    }

    public static func from(_ summary: CatalogTrackSummary) -> TrackCard {
        TrackCard(
            globalID: summary.globalID,
            title: summary.title,
            artistName: summary.artistName,
            albumTitle: summary.albumTitle,
            duration: summary.duration,
            isFavorite: summary.isFavorite
        )
    }

    public static func from(_ track: Track) -> TrackCard {
        TrackCard(
            globalID: GlobalID(serverID: track.serverID, remoteID: track.id.rawValue),
            title: track.title,
            artistName: track.artistName,
            albumTitle: track.albumTitle,
            duration: track.duration,
            isFavorite: track.isFavorite
        )
    }
}

/// 专辑卡片。
public struct AlbumCard: Codable, Sendable, Identifiable, Hashable {
    public var id: GlobalID { globalID }
    public let globalID: GlobalID
    public let title: String
    public let artistName: String

    public init(globalID: GlobalID, title: String, artistName: String) {
        self.globalID = globalID
        self.title = title
        self.artistName = artistName
    }
}

/// 聊天消息（用户 / 助手），内容为结构化消息数组，便于 UI 渲染卡片。
public struct AgentChatMessage: Codable, Sendable, Identifiable {
    public enum Role: String, Codable, Sendable { case user, assistant }
    public let id: UUID
    public let role: Role
    public let messages: [AgentMessage]
    public let createdAt: Date

    public init(id: UUID = UUID(), role: Role, messages: [AgentMessage], createdAt: Date = .now) {
        self.id = id
        self.role = role
        self.messages = messages
        self.createdAt = createdAt
    }
}
