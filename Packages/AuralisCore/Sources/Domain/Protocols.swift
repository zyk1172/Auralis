import Foundation

public protocol MusicLibraryRepository: Sendable {
    func artists(offset: Int, limit: Int) async throws -> [Artist]
    func albums(offset: Int, limit: Int) async throws -> [Album]
    func tracks(offset: Int, limit: Int) async throws -> [Track]
    func track(id: TrackID) async throws -> Track?
    func search(query: String, limit: Int) async throws -> [Track]
}

public protocol PlaybackControlling: Sendable {
    func state() async -> PlaybackState
    func play(track: Track) async throws
    func pause() async
    func resume() async throws
    func stop() async
    /// 设置播放器音量（0...1）。引擎可选择实现；默认空实现保证兼容性。
    func setVolume(_ volume: Float) async
    /// 设置播放速度（0.5...2.0）。默认空实现（1.0x）。
    func setRate(_ rate: Float) async
    /// 拖动到指定播放位置（秒）。
    func seek(to position: TimeInterval) async
    /// 引擎当前真实播放位置；无法获取时返回 nil，调用方回退到估算。
    func currentPosition() async -> TimeInterval?
    /// 注册曲目自然播完的通知回调（用于自动切歌）。
    func setTrackEndedHandler(_ handler: (@Sendable () -> Void)?) async
    /// 注册播放中途失败回调（流地址失效 / 解码失败 / 网络错误），用于刷新 URL 后重试或自动下一首。
    func setPlaybackFailureHandler(_ handler: (@Sendable () -> Void)?) async
}

public extension PlaybackControlling {
    func setVolume(_ volume: Float) async {}
    func setRate(_ rate: Float) async {}
    func seek(to position: TimeInterval) async {}
    func currentPosition() async -> TimeInterval? { nil }
    func setTrackEndedHandler(_ handler: (@Sendable () -> Void)?) async {}
    func setPlaybackFailureHandler(_ handler: (@Sendable () -> Void)?) async {}
}

/// 循环模式：关闭 / 列表循环 / 单曲循环。
public enum RepeatMode: String, CaseIterable, Codable, Sendable {
    case off
    case all
    case one

    public var title: String {
        switch self {
        case .off: String(localized: "不循环")
        case .all: String(localized: "列表循环")
        case .one: String(localized: "单曲循环")
        }
    }

    public var symbol: String {
        switch self {
        case .off: "repeat"
        case .all: "repeat"
        case .one: "repeat.1"
        }
    }

    public var next: RepeatMode {
        switch self {
        case .off: .all
        case .all: .one
        case .one: .off
        }
    }
}

public protocol MetadataAgent: Sendable {
    func preview(trackID: TrackID, overlay: MetadataOverlay) async throws -> MetadataWritePreview
    func apply(previewID: UUID) async throws
    func rollback(auditID: UUID) async throws
}

public struct MetadataWritePreview: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let trackID: TrackID
    public let changedFields: [String]
    public let backupPlanned: Bool
    public init(id: UUID = UUID(), trackID: TrackID, changedFields: [String], backupPlanned: Bool) {
        self.id = id
        self.trackID = trackID
        self.changedFields = changedFields
        self.backupPlanned = backupPlanned
    }
}

public protocol QueuePersisting: Sendable {
    func save(trackIDs: [TrackID], currentIndex: Int?, position: TimeInterval) async throws
    func restore() async throws -> RestoredQueue?
}

public struct RestoredQueue: Codable, Hashable, Sendable {
    public let trackIDs: [TrackID]
    public let currentIndex: Int?
    public let position: TimeInterval
    public init(trackIDs: [TrackID], currentIndex: Int?, position: TimeInterval) {
        self.trackIDs = trackIDs
        self.currentIndex = currentIndex
        self.position = position
    }
}
