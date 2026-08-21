import Application
import Domain
import Foundation
import LocalCatalog
import LyricsKit
import MusicLibrary
import Observability
import OfflineManager

/// 本地音乐目录的运行时协调器。
///
/// 负责：打开 SQLite 目录库、触发首次全量同步 / 增量同步 / 手动刷新 / 后台刷新、
/// 汇报进度、支持取消，以及服务器移除后的本地清理。
/// 不负责播放，也不会把整库内容交给大模型。
@MainActor
public final class CatalogCoordinator: ObservableObject {
    /// 同步的可视状态。
    public enum SyncPhase: Equatable, Sendable {
        case idle
        case running(stage: String, processed: Int)
        case succeeded(tracks: Int, at: Date)
        /// 快速路径：本地与网络曲目数一致，判定目录已是最新，跳过整库拉取。
        case upToDate(tracks: Int)
        case failed(String)
        case cancelled
    }

    @Published public private(set) var phase: SyncPhase = .idle

    /// 一次同步成功完成后的回调（参数：serverID、本次处理曲目数）。
    /// AppShell 用它刷新曲库分类索引文件等派生数据。
    public var onSyncCompleted: ((ServerID, Int) -> Void)?
    @Published public private(set) var lastReport: LibrarySyncReport?
    /// 各服务器的同步状态，供 Agent 的 getSyncStatus 使用。
    @Published public private(set) var statuses: [CatalogSyncStatus] = []

    /// 本地目录库（Agent 与搜索直接读取）。
    public let store: LocalCatalogStore

    private let connector: any ServerConnecting
    /// 音频离线缓存：删除服务器时按 serverID 清理（P0-1/P2-16）。
    private let trackCache: TrackCacheStore
    /// 歌词磁盘缓存（含负缓存）：删除服务器时按 serverID 清理（P0-2/P2-16）。
    private let lyricsCache: LyricsDiskCache
    private var synchronizer: LibrarySynchronizer?
    private var syncTask: Task<Void, Never>?
    private var syncingServerID: ServerID?
    private let now: @Sendable () -> Date

    /// Foreground transitions are frequent (Control Center, calls, permission sheets). A recent
    /// successful catalog must not trigger even the album-count probe on every transition.
    public static let foregroundSyncCooldown: TimeInterval = 15 * 60
    /// 专辑级指纹无法覆盖“同专辑、同曲目数、只改单曲元数据”，因此至少每天做一次完整校验。
    public static let weakProbeFullValidationInterval: TimeInterval = 24 * 60 * 60

    public init(
        connector: any ServerConnecting,
        store: LocalCatalogStore,
        trackCache: TrackCacheStore = TrackCacheStore(),
        lyricsCache: LyricsDiskCache = LyricsDiskCache(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.connector = connector
        self.trackCache = trackCache
        self.lyricsCache = lyricsCache
        self.now = now
        self.store = store
        let reusedAt = ContinuousClock.now
        StartupPerformanceTrace.record(.catalogStoreOpenCoordinator, since: reusedAt)
    }

    /// 测试与非生产组合的便利入口。生产 AppModel 注入 composition root 已创建的 store，
    /// 不会走这里再次打开 catalog.sqlite。
    public convenience init(
        connector: any ServerConnecting,
        storeURL: URL? = nil,
        trackCache: TrackCacheStore = TrackCacheStore(),
        lyricsCache: LyricsDiskCache = LyricsDiskCache(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        let url = storeURL ?? Self.defaultStoreURL()
        // 目录库打不开时退化到内存库，保证 App 仍可运行（只是无本地目录能力）。
        // 内存库几乎不会失败；万一失败再试独立临时文件，仍失败才显式记录 fault。
        var store = (try? LocalCatalogStore(url: url))
            ?? (try? LocalCatalogStore(url: URL(string: "file::memory:")!))
        if store == nil {
            store = try? LocalCatalogStore(
                url: FileManager.default.temporaryDirectory
                    .appendingPathComponent("auralis-catalog-\(UUID().uuidString).sqlite")
            )
        }
        guard let store else {
            AuralisLog.library.fault("catalogStoreOpenFailed: 无法创建任何本地目录存储")
            preconditionFailure("无法初始化本地目录存储")
        }
        self.init(
            connector: connector,
            store: store,
            trackCache: trackCache,
            lyricsCache: lyricsCache,
            now: now
        )
    }

    /// 目录库位置：优先使用 App Group 共享容器（供 Siri/小组件等扩展读取），
    /// 未配置 App Group 时回退到 App 沙盒 Application Support。
    public static func defaultStoreURL() -> URL {
        LocalCatalogStore.defaultStoreURL(appGroupIdentifier: Self.appGroupIdentifier)
    }

    /// App Group 标识：App、Siri Intents 扩展、小组件共用。
    public static let appGroupIdentifier = "group.com.auralis.player"

    // MARK: - Server registration

    /// 连接成功后登记服务器，并决定首次全量还是增量同步。
    public func registerAndSync(account: ServerAccount) async {
        try? await store.upsertServer(account)
        let status = await currentStatus(for: account.id)
        // 同步元数据可能来自旧版本而缺失，但 SQLite 里已经有完整歌曲元数据。
        // 不能因为少了一条 lastCompletedAt 就每次误走“首次全量同步”；只要本地目录
        // 已有歌曲，先做轻量的服务器曲目数比对，真正不一致时才拉取。
        let localTrackCount = (try? await store.trackCount(serverID: account.id)) ?? 0
        let hasUsableLocalCatalog = localTrackCount > 0
        if hasUsableLocalCatalog, isInsideForegroundCooldown(status) {
            phase = .upToDate(tracks: localTrackCount)
            return
        }
        let mode: LibrarySyncMode = (status?.lastCompletedAt == nil && !hasUsableLocalCatalog)
            ? .full
            : .incremental
        startSync(serverID: account.id, mode: mode, skipIfUpToDate: true)
    }

    // MARK: - Sync control

    /// 手动刷新（用户在设置中点击「立即刷新」）。
    public func manualRefresh(serverID: ServerID) {
        startSync(serverID: serverID, mode: .incremental)
    }

    /// 强制全量重建（目录疑似损坏或用户要求）。
    public func fullRebuild(serverID: ServerID) {
        startSync(serverID: serverID, mode: .full)
    }

    /// 后台刷新入口（iOS BGAppRefresh / macOS 定时器都可调用）。
    public func backgroundRefresh(serverID: ServerID) async {
        guard syncTask == nil else { return }
        let status = await currentStatus(for: serverID)
        let localTrackCount = (try? await store.trackCount(serverID: serverID)) ?? 0
        if localTrackCount > 0, isInsideForegroundCooldown(status) {
            phase = .upToDate(tracks: localTrackCount)
            return
        }
        startSync(serverID: serverID, mode: .incremental, skipIfUpToDate: true)
        await syncTask?.value
    }

    /// 同步失败后的重试。
    public func retry(serverID: ServerID) {
        startSync(serverID: serverID, mode: .incremental)
    }

    public func cancelSync() {
        guard let serverID = syncingServerID, let synchronizer else {
            syncTask?.cancel()
            return
        }
        Task { await synchronizer.requestCancellation(serverID: serverID) }
        syncTask?.cancel()
    }

    private func startSync(serverID: ServerID, mode: LibrarySyncMode, skipIfUpToDate: Bool = false) {
        guard syncTask == nil else { return }
        syncingServerID = serverID
        phase = .running(
            stage: mode == .full
                ? String(localized: "首次全量同步", bundle: .module)
                : (skipIfUpToDate
                    ? String(localized: "检查本地目录是否最新", bundle: .module)
                    : String(localized: "增量同步", bundle: .module)),
            processed: 0
        )
        let syncStartedAt = ContinuousClock.now
        let serverHash = StartupPerformanceTrace.redactedServerID(serverID.rawValue)
        StartupPerformanceTrace.record(
            .backgroundSyncStarted,
            since: syncStartedAt,
            metadata: .init(serverIDHash: serverHash)
        )

        syncTask = Task { [store, connector] in
            var completedTrackCount = 0
            defer {
                StartupPerformanceTrace.record(
                    .backgroundSyncFinished,
                    since: syncStartedAt,
                    metadata: .init(entityCount: completedTrackCount, serverIDHash: serverHash)
                )
                self.syncTask = nil
                self.syncingServerID = nil
            }
            var effectiveMode = mode
            var observedProbe: LibraryRevisionProbe?
            if mode == .incremental, skipIfUpToDate,
               let local = try? await store.trackCount(serverID: serverID),
               let probe = await connector.libraryRevisionProbe(serverID: serverID) {
                observedProbe = probe
                let stored = await store.remoteProbeState(for: serverID)
                let countMatches = probe.songCount == local
                let fingerprintMatches = probe.fingerprint != nil && probe.fingerprint == stored.fingerprint
                let authoritative = probe.kind == .authoritativeRevision
                let validationAge = stored.lastValidatedAt.map { self.now().timeIntervalSince($0) }
                let weakProbeValidationDue = validationAge == nil
                    || validationAge! < 0
                    || validationAge! >= Self.weakProbeFullValidationInterval

                // 总数相同绝不是充分条件。只有真实 revision 相同，或弱指纹相同且最近做过
                // 完整校验，才允许跳过。countOnly、首次没有基线、指纹变化都进入完整替换。
                if countMatches, fingerprintMatches, authoritative || !weakProbeValidationDue {
                    try? await store.recordRemoteProbe(
                        serverID: serverID,
                        fingerprint: probe.fingerprint,
                        kind: probe.kind.rawValue,
                        probedAt: probe.fetchedAt,
                        markValidated: false
                    )
                    self.phase = .upToDate(tracks: local)
                    return
                }
                effectiveMode = .full
                let stage: String
                if !countMatches {
                    stage = String(localized: "检测到曲目数量变化，完整更新", bundle: .module)
                } else if probe.kind == .countOnly {
                    stage = String(localized: "服务器仅提供数量，执行完整校验", bundle: .module)
                } else if stored.fingerprint == nil {
                    stage = String(localized: "建立服务器修订基线，完整校验", bundle: .module)
                } else if !fingerprintMatches {
                    stage = String(localized: "检测到资料库内容变化，完整更新", bundle: .module)
                } else {
                    stage = String(localized: "定期完整校验单曲元数据", bundle: .module)
                }
                self.phase = .running(stage: stage, processed: 0)
            }
            guard let synchronizer = await connector.makeSynchronizer(serverID: serverID, store: store) else {
                self.phase = .failed(String(localized: "未连接服务器，无法同步目录", bundle: .module))
                return
            }
            self.synchronizer = synchronizer
            do {
                let report = try await synchronizer.sync(serverID: serverID, mode: effectiveMode) { progress in
                    await MainActor.run {
                        self.phase = .running(
                            stage: Self.stageTitle(progress.stage, section: progress.section),
                            processed: progress.processedCount
                        )
                    }
                }
                self.lastReport = report
                completedTrackCount = report.trackCount
                let finalProbe: LibraryRevisionProbe?
                if let observedProbe {
                    finalProbe = observedProbe
                } else {
                    finalProbe = await connector.libraryRevisionProbe(serverID: serverID)
                }
                if let finalProbe {
                    try? await store.recordRemoteProbe(
                        serverID: serverID,
                        fingerprint: finalProbe.fingerprint,
                        kind: finalProbe.kind.rawValue,
                        probedAt: finalProbe.fetchedAt,
                        markValidated: effectiveMode == .full
                    )
                }
                self.phase = .succeeded(tracks: report.trackCount, at: report.completedAt)
                await self.refreshStatuses()
                self.onSyncCompleted?(serverID, report.trackCount)
            } catch is CancellationError {
                self.phase = .cancelled
            } catch let error as LibrarySyncError {
                self.phase = .failed(Self.describe(error))
            } catch {
                // 统一分类：本地网络被拒 / 超时 / 认证 / HTTP / OpenSubsonic 解码 /
                // SQLite 读写失败等各有明确文案，不能全部退化成笼统的「同步失败」。
                self.phase = .failed(ConnectionErrorDescription.describe(error))
            }
        }
    }

    // MARK: - Status

    public func refreshStatuses() async {
        let servers = (try? await store.listServers()) ?? []
        var result: [CatalogSyncStatus] = []
        for server in servers {
            let running = (syncingServerID == server.id)
            result.append(await store.syncStatus(for: server.id, isRunning: running))
        }
        statuses = result
    }

    private func currentStatus(for serverID: ServerID) async -> CatalogSyncStatus? {
        await store.syncStatus(for: serverID)
    }

    private func isInsideForegroundCooldown(_ status: CatalogSyncStatus?) -> Bool {
        guard let completedAt = status?.lastCompletedAt else { return false }
        let elapsed = now().timeIntervalSince(completedAt)
        return elapsed >= 0 && elapsed < Self.foregroundSyncCooldown
    }

    // MARK: - 服务器在线拉取

    /// 按 ID 从服务器拉取单曲（含流地址）：Agent 播放本地目录尚未同步的歌曲时，
    /// 由 AuralisAgentBridge 走这条路径做「服务器曲目在线流播」。
    /// 按 serverID 路由（R01）；失败返回 nil（Agent 侧统一按“不可用”处理）。
    public func serverTrack(serverID: ServerID, id: TrackID) async -> Track? {
        try? await connector.serverTrack(serverID: serverID, trackID: id)
    }

    // MARK: - Cleanup

    /// 删除服务器：清理本地目录、下载与会话关联，以及该服务器的磁盘缓存
    /// （音频 / 歌词含负缓存），不触碰 NAS / 远端数据。
    public func purgeLocalData(serverID: ServerID) async {
        try? await store.purgeServer(serverID)
        // P0-1 / P0-2 / P2-16：按 serverID 清理音频与歌词缓存（含负缓存），
        // 避免移除服务器后残留离线文件/负缓存被新服务器误用。
        await trackCache.removeAll(forServer: serverID)
        await lyricsCache.removeAll(forServer: serverID)
        await refreshStatuses()
        phase = .idle
    }

    // MARK: - Helpers

    private static func stageTitle(_ stage: LibrarySyncProgress.Stage, section: LibrarySyncSection?) -> String {
        switch stage {
        case .beginning: return String(localized: "准备同步", bundle: .module)
        case .fetching:
            switch section {
            case .artists: return String(localized: "拉取艺术家", bundle: .module)
            case .albums: return String(localized: "拉取专辑", bundle: .module)
            case .tracks: return String(localized: "拉取单曲", bundle: .module)
            case .none: return String(localized: "拉取数据", bundle: .module)
            }
        case .persisting:
            switch section {
            case .artists: return String(localized: "写入艺术家", bundle: .module)
            case .albums: return String(localized: "写入专辑", bundle: .module)
            case .tracks: return String(localized: "写入单曲", bundle: .module)
            case .none: return String(localized: "写入本地", bundle: .module)
            }
        case .completedSection:
            switch section {
            case .artists: return String(localized: "艺术家完成", bundle: .module)
            case .albums: return String(localized: "专辑完成", bundle: .module)
            case .tracks: return String(localized: "单曲完成", bundle: .module)
            case .none: return String(localized: "分段完成", bundle: .module)
            }
        case .completed: return String(localized: "同步完成", bundle: .module)
        }
    }

    private static func describe(_ error: LibrarySyncError) -> String {
        switch error {
        case let .alreadyRunning(id): String(localized: "服务器 \(id.rawValue) 正在同步中", bundle: .module)
        case let .invalidPageSize(size): String(localized: "分页大小非法：\(size)", bundle: .module)
        case let .invalidRecordServer(section, recordID, expected, actual):
            String(localized: "\(section.rawValue) 记录 \(recordID) 服务器不匹配（期望 \(expected.rawValue)，实际 \(actual.rawValue)）", bundle: .module)
        case let .duplicateRecord(section, recordID): String(localized: "\(section.rawValue) 出现重复记录：\(recordID)", bundle: .module)
        case let .continuationLoop(section, _): String(localized: "\(section.rawValue) 分页出现循环，已中止", bundle: .module)
        case let .pageLimitExceeded(section, maximum): String(localized: "\(section.rawValue) 超过最大分页数 \(maximum)", bundle: .module)
        case let .unknownSession(id): String(localized: "同步会话不存在：\(id.uuidString)", bundle: .module)
        case .sessionMismatch: String(localized: "同步会话不一致，请重试", bundle: .module)
        }
    }
}
