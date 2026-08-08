import Domain
import Foundation
import LocalCatalog

/// 推荐反馈类型（需求 8）。
public enum RecommendationFeedback: String, Codable, Sendable, CaseIterable, Identifiable {
    case liked = "liked"
    case notInterested = "notInterested"
    case quieter = "quieter"
    case morePowerful = "morePowerful"
    case moreObscure = "moreObscure"
    case lessArtist = "lessArtist"
    case excludeRecent = "excludeRecent"
    case moreSimilar = "moreSimilar"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .liked: "喜欢"
        case .notInterested: "不感兴趣"
        case .quieter: "更安静"
        case .morePowerful: "更有力量"
        case .moreObscure: "更冷门"
        case .lessArtist: "少推荐该艺术家"
        case .excludeRecent: "排除最近播放"
        case .moreSimilar: "查找更多相似"
        }
    }
}

/// 单条推荐反馈记录。
public struct FeedbackRecord: Codable, Sendable, Identifiable {
    public let id: UUID
    public let trackID: GlobalID
    public let kind: RecommendationFeedback
    public let at: Date

    public init(id: UUID = UUID(), trackID: GlobalID, kind: RecommendationFeedback, at: Date = .now) {
        self.id = id
        self.trackID = trackID
        self.kind = kind
        self.at = at
    }
}

/// 本地结构化用户偏好。
public struct UserPreferences: Codable, Sendable {
    public var likedGenres: [String]
    public var likedArtists: [GlobalID]
    public var excludedArtists: [GlobalID]
    public var ratings: [String: Int]        // GlobalID 字符串 -> 评分
    public var skipCounts: [String: Int]
    public var completionRates: [String: Double]
    public var commonScenes: [String]
    public var repeatTolerance: Double        // 0...1，越高越能接受重复
    public var preferredPlaylistDuration: TimeInterval
    public var feedback: [FeedbackRecord]

    public init(
        likedGenres: [String] = [],
        likedArtists: [GlobalID] = [],
        excludedArtists: [GlobalID] = [],
        ratings: [String: Int] = [:],
        skipCounts: [String: Int] = [:],
        completionRates: [String: Double] = [:],
        commonScenes: [String] = [],
        repeatTolerance: Double = 0.5,
        preferredPlaylistDuration: TimeInterval = 3600,
        feedback: [FeedbackRecord] = []
    ) {
        self.likedGenres = likedGenres
        self.likedArtists = likedArtists
        self.excludedArtists = excludedArtists
        self.ratings = ratings
        self.skipCounts = skipCounts
        self.completionRates = completionRates
        self.commonScenes = commonScenes
        self.repeatTolerance = repeatTolerance
        self.preferredPlaylistDuration = preferredPlaylistDuration
        self.feedback = feedback
    }
}

/// 用户偏好持久化与读写。
public actor PreferencesStore {
    private let fileURL: URL
    private var preferences: UserPreferences

    public init(fileURL: URL) {
        self.fileURL = fileURL
        self.preferences = Self.load(from: fileURL) ?? UserPreferences()
    }

    public var current: UserPreferences { preferences }

    public func update(_ mutation: @Sendable (inout UserPreferences) -> Void) {
        var copy = preferences
        mutation(&copy)
        preferences = copy
        try? persist()
    }

    public func recordFeedback(trackID: GlobalID, kind: RecommendationFeedback) {
        update { $0.feedback.append(FeedbackRecord(trackID: trackID, kind: kind)) }
    }

    public func removeFeedback(_ id: UUID) {
        update { $0.feedback.removeAll { $0.id == id } }
    }

    public func clear() {
        preferences = UserPreferences()
        try? persist()
    }

    private func persist() throws {
        let data = try JSONEncoder().encode(preferences)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL)
    }

    private static func load(from url: URL) -> UserPreferences? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(UserPreferences.self, from: data)
    }
}
