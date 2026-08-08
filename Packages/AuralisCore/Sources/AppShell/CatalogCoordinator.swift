import Application
import Domain
import Foundation
import LocalCatalog
import LyricsKit
import MusicLibrary
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

    public init(
        connector: any ServerConnecting,
        storeURL: URL? = nil,
        trackCache: TrackCacheStore = TrackCacheStore(),
        lyricsCache: LyricsDiskCache = LyricsDiskCache()
    ) {
        self.connector = connector
        self.trackCache = trackCache
        self.lyricsCache = lyricsCache
        let url = storeURL ?? Self.defaultStoreURL()
        // 目录库打不开时退化到内存库，保证 App 仍可运行（只是无本地目录能力）。
        self.store = (try? LocalCatalogStore(url: url)) ?? (try! LocalCatalogStore(url: URL(fileURLWithPath: ":memory:")))
    }

    /// 目录库位置：优先使用 App Group 共享容器（供 Siri/小组件等扩展读取），
    /// 未配置 App Group 时回退到 App 沙盒 Application Support。
    public static func defaultStoreURL() -> URL {
        let manager = FileManager.default
        let base: URL
        if let group = manager.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupIdentifier) {
            base = group
        } else {
            base = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? manager.temporaryDirectory
        }
        let dir = base.appendingPathComponent("Auralis", isDirectory: true)
        try? manager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("catalog.sqlite")
    }

    /// App Group 标识：App、Siri Intents 扩展、小组件共用。
    public static let appGroupIdentifier = "group.com.auralis.player"

    // MARK: - Server registration

    /// 连接成功后登记服务器，并决定首次全量还是增量同步。
    public func registerAndSync(account: ServerAccount) async {
        try? await store.upsertServer(account)
        let status = await currentStatus(for: account.id)
        // 从未成功同步过 → 首次全量；已同步过 → 增量。
        let mode: LibrarySyncMode = (status?.lastCompletedAt == nil) ? .full : .incremental
        startSync(serverID: account.id, mode: mode)
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
        startSync(serverID: serverID, mode: .incremental)
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

    private func startSync(serverID: ServerID, mode: LibrarySyncMode) {
        guard syncTask == nil else { return }
        syncingServerID = serverID
        phase = .running(stage: mode == .full ? "首次全量同步" : "增量同步", processed: 0)

        syncTask = Task { [store, connector] in
            defer {
                self.syncTask = nil
                self.syncingServerID = nil
            }
            guard let synchronizer = await connector.makeSynchronizer(store: store) else {
                self.phase = .failed("未连接服务器，无法同步目录")
                return
            }
            self.synchronizer = synchronizer
            do {
                let report = try await synchronizer.sync(serverID: serverID, mode: mode) { progress in
                    await MainActor.run {
                        self.phase = .running(
                            stage: Self.stageTitle(progress.stage, section: progress.section),
                            processed: progress.processedCount
                        )
                    }
                }
                self.lastReport = report
                self.phase = .succeeded(tracks: report.trackCount, at: report.completedAt)
                await self.refreshStatuses()
                self.onSyncCompleted?(serverID, report.trackCount)
            } catch is CancellationError {
                self.phase = .cancelled
            } catch let error as LibrarySyncError {
                self.phase = .failed(Self.describe(error))
            } catch {
                self.phase = .failed(error.localizedDescription)
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
        let sectionTitle: String
        switch section {
        case .artists: sectionTitle = "艺术家"
        case .albums: sectionTitle = "专辑"
        case .tracks: sectionTitle = "单曲"
        case .none: sectionTitle = ""
        }
        switch stage {
        case .beginning: return "准备同步"
        case .fetching: return sectionTitle.isEmpty ? "拉取数据" : "拉取\(sectionTitle)"
        case .persisting: return sectionTitle.isEmpty ? "写入本地" : "写入\(sectionTitle)"
        case .completedSection: return sectionTitle.isEmpty ? "分段完成" : "\(sectionTitle)完成"
        case .completed: return "同步完成"
        }
    }

    private static func describe(_ error: LibrarySyncError) -> String {
        switch error {
        case let .alreadyRunning(id): "服务器 \(id.rawValue) 正在同步中"
        case let .invalidPageSize(size): "分页大小非法：\(size)"
        case let .invalidRecordServer(section, recordID, expected, actual):
            "\(section.rawValue) 记录 \(recordID) 服务器不匹配（期望 \(expected.rawValue)，实际 \(actual.rawValue)）"
        case let .duplicateRecord(section, recordID): "\(section.rawValue) 出现重复记录：\(recordID)"
        case let .continuationLoop(section, _): "\(section.rawValue) 分页出现循环，已中止"
        case let .pageLimitExceeded(section, maximum): "\(section.rawValue) 超过最大分页数 \(maximum)"
        case let .unknownSession(id): "同步会话不存在：\(id.uuidString)"
        case .sessionMismatch: "同步会话不一致，请重试"
        }
    }
}
