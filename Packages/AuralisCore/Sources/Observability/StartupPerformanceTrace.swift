import Foundation
import OSLog

/// 冷启动关键路径的真实计时。所有阶段使用 `ContinuousClock`，同时写入统一日志与
/// signpost，便于在 Console 和 Instruments 中把 SQLite、恢复、apply 与后台同步分开。
///
/// 元数据只接受计数、字节数和服务器 ID 的不可逆短哈希；不会记录凭据、URL 或路径。
public enum StartupPerformanceTrace {
    public enum Phase: String, Sendable {
        case appModelInit = "APP_MODEL_INIT"
        case persistenceInit = "PERSISTENCE_INIT"
        case catalogStoreOpenConnector = "CATALOG_STORE_OPEN_CONNECTOR"
        case catalogStoreOpenCoordinator = "CATALOG_STORE_OPEN_COORDINATOR"
        case sqliteOpen = "SQLITE_OPEN"
        case sqliteSchema = "SQLITE_SCHEMA"
        case sqliteQuickCheck = "SQLITE_QUICK_CHECK"
        case sqliteMigrations = "SQLITE_MIGRATIONS"
        case restoreDislikeMigration = "RESTORE_DISLIKE_MIGRATION"
        case restoreAccount = "RESTORE_ACCOUNT"
        case legacySnapshotMigration = "LEGACY_SNAPSHOT_MIGRATION"
        case restoreArtists = "RESTORE_ARTISTS"
        case restoreAlbums = "RESTORE_ALBUMS"
        case restoreTracks = "RESTORE_TRACKS"
        case restoreStreamURLs = "RESTORE_STREAM_URLS"
        case appApplyDedupe = "APP_APPLY_DEDUPE"
        case appApplyGenres = "APP_APPLY_GENRES"
        case appApplyLibraryAdded = "APP_APPLY_LIBRARY_ADDED"
        case appApplyHomeSnapshot = "APP_APPLY_HOME_SNAPSHOT"
        case localCatalogReady = "LOCAL_CATALOG_READY"
        case serverConnectionStateConnected = "SERVER_CONNECTION_STATE_CONNECTED"
        case backgroundSyncStarted = "BACKGROUND_SYNC_STARTED"
        case backgroundSyncFinished = "BACKGROUND_SYNC_FINISHED"
        case refreshCatalogFromStore = "REFRESH_CATALOG_FROM_STORE"
    }

    public struct Metadata: Sendable, Equatable {
        public var entityCount: Int?
        public var fileBytes: Int?
        public var serverIDHash: String?
        public var fallbackUsed: Bool?

        public init(
            entityCount: Int? = nil,
            fileBytes: Int? = nil,
            serverIDHash: String? = nil,
            fallbackUsed: Bool? = nil
        ) {
            self.entityCount = entityCount
            self.fileBytes = fileBytes
            self.serverIDHash = serverIDHash
            self.fallbackUsed = fallbackUsed
        }

        fileprivate var summary: String {
            var fields: [String] = []
            if let entityCount { fields.append("count=\(entityCount)") }
            if let fileBytes { fields.append("bytes=\(fileBytes)") }
            if let serverIDHash { fields.append("server=\(serverIDHash)") }
            if let fallbackUsed { fields.append("fallback=\(fallbackUsed)") }
            return fields.joined(separator: " ")
        }
    }

    private static let logger = Logger(subsystem: "com.auralis.player", category: "StartupPerformance")
    private static let signpostLog = OSLog(subsystem: "com.auralis.player", category: "StartupPerformance")

    @discardableResult
    public static func measure<T>(
        _ phase: Phase,
        metadata: Metadata = .init(),
        operation: () throws -> T
    ) rethrows -> T {
        let startedAt = ContinuousClock.now
        let signpostID = OSSignpostID(log: signpostLog)
        os_signpost(.begin, log: signpostLog, name: "AuralisStartupPhase", signpostID: signpostID, "%{public}s", phase.rawValue)
        defer {
            os_signpost(.end, log: signpostLog, name: "AuralisStartupPhase", signpostID: signpostID, "%{public}s", phase.rawValue)
            record(phase, since: startedAt, metadata: metadata)
        }
        return try operation()
    }

    @discardableResult
    public static func measure<T>(
        _ phase: Phase,
        metadata: Metadata = .init(),
        operation: () async throws -> T
    ) async rethrows -> T {
        let startedAt = ContinuousClock.now
        let signpostID = OSSignpostID(log: signpostLog)
        os_signpost(.begin, log: signpostLog, name: "AuralisStartupPhase", signpostID: signpostID, "%{public}s", phase.rawValue)
        defer {
            os_signpost(.end, log: signpostLog, name: "AuralisStartupPhase", signpostID: signpostID, "%{public}s", phase.rawValue)
            record(phase, since: startedAt, metadata: metadata)
        }
        return try await operation()
    }

    public static func record(
        _ phase: Phase,
        since startedAt: ContinuousClock.Instant,
        metadata: Metadata = .init()
    ) {
        let milliseconds = durationMilliseconds(startedAt.duration(to: .now))
        let suffix = metadata.summary
        logger.notice("AuralisStartup phase=\(phase.rawValue, privacy: .public) duration_ms=\(milliseconds, privacy: .public) \(suffix, privacy: .public)")
    }

    /// 只用于日志关联，不输出原始 server ID。
    public static func redactedServerID(_ rawValue: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in rawValue.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16).prefix(12).description
    }

    private static func durationMilliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }
}
