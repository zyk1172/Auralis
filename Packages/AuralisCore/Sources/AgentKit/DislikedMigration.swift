import Foundation
import LocalCatalog

/// 旧「不感兴趣」反馈历史 → disliked_tracks 权威状态的一次性、幂等迁移。
///
/// 旧的 `RecommendationFeedback.notInterested` FeedbackRecord 只是反馈事件历史；
/// 本轮开始 `disliked_tracks`（SQLite，GlobalID 为键）是唯一权威状态。
/// 迁移后旧 FeedbackRecord 仍保留作为历史反馈事件，不删除。
public enum DislikedMigration {
    /// 迁移完成标记：避免每次启动重复扫描。
    public static let migrationCompletedDefaultsKey = "auralis.dislike.migratedFromNotInterested.v1"

    /// 执行迁移。已在 `defaults` 标记完成时直接返回 0（幂等）。
    /// - Returns: 本次实际迁移的条数。
    @discardableResult
    public static func migrateNotInterestedFeedback(
        catalog: LocalCatalogStore,
        preferences: PreferencesStore,
        defaults: UserDefaults = .standard
    ) async throws -> Int {
        guard !defaults.bool(forKey: migrationCompletedDefaultsKey) else { return 0 }

        let records = await preferences.current.feedback.filter { $0.kind == .notInterested }
        var migrated = 0
        for record in records {
            try await catalog.setDisliked(
                record.trackID,
                value: true,
                source: "migration:notInterestedFeedback"
            )
            migrated += 1
        }
        defaults.set(true, forKey: migrationCompletedDefaultsKey)
        return migrated
    }
}
