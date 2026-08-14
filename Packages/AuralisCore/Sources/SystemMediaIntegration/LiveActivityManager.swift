import Domain
import Foundation
import Observability
#if os(iOS)
import ActivityKit
#endif

/// 灵动岛 / 锁屏实时活动（Live Activity）与「正在播放」小组件的统一数据源。
///
/// 之前 Live Activity 与小组件已声明但从未被驱动（没有任何 Activity.request / 更新，
/// 也没有写入 playback-snapshot.json），导致灵动岛不出现、小组件永远显示空态。
/// 本管理器：
/// - 每次播放状态变化时写入 App Group 的 playback-snapshot.json（驱动小组件）；
/// - 首次播放时请求 Live Activity，之后按节流更新（ActivityKit 有更新频率限额）；
/// - 停止 / 队列结束 / 移除服务器时结束活动并清空快照。
///
/// ActivityKit 的 `Activity.update/end` 是 nonisolated async；在 Swift 6 严格并发下
/// 直接把非 Sendable 的 Activity 送进 await 会报 data-race。这里用 `@unchecked Sendable`
/// 的不变句柄持有 Activity，只把句柄（Sendable）送过隔离边界。
@MainActor
public final class LiveActivityManager {
    public static let shared = LiveActivityManager()

    /// 与 CatalogCoordinator.appGroupIdentifier / 小组件读取路径保持一致。
    private static let appGroupIdentifier = "group.com.auralis.player"
    private static let snapshotRelativePath = "Auralis/playback-snapshot.json"
    /// ActivityKit 对更新频率有限额；5 秒内的重复更新直接跳过。
    private static let activityUpdateInterval: TimeInterval = 5

    #if os(iOS)
    private var activityHandle: LiveActivityHandle?
    #else
    private var activityHandle: Never?
    #endif
    private var lastActivityUpdate: Date = .distantPast

    public init() {}

    /// 播放状态变化（切歌 / 播放 / 暂停 / 拖动）时调用。始终写小组件快照；
    /// 活动按节流更新，首次请求。
    public func updatePlayback(_ state: PlaybackActivityAttributes.ContentState) async {
        writeSnapshot(state)
        #if os(iOS)
        if activityHandle == nil {
            await requestActivity(state)
            return
        }
        guard Date().timeIntervalSince(lastActivityUpdate) >= Self.activityUpdateInterval else { return }
        let content = ActivityContent(state: state, staleDate: .now.addingTimeInterval(60))
        lastActivityUpdate = .now
        await activityHandle?.activity.update(content)
        #endif
    }

    /// 停止 / 队列结束 / 移除服务器：结束活动并清空小组件快照。
    public func endPlayback() async {
        #if os(iOS)
        if let handle = activityHandle {
            activityHandle = nil
            await handle.activity.end(nil, dismissalPolicy: .immediate)
        }
        #endif
        clearSnapshot()
    }

    #if os(iOS)
    private func requestActivity(_ state: PlaybackActivityAttributes.ContentState) async {
        let attributes = PlaybackActivityAttributes(activityID: UUID().uuidString)
        let content = ActivityContent(state: state, staleDate: .now.addingTimeInterval(60))
        do {
            let newActivity = try Activity.request(attributes: attributes, content: content)
            activityHandle = LiveActivityHandle(newActivity)
            lastActivityUpdate = .now
        } catch {
            AuralisLog.playback.warning("Live Activity 请求失败：\(error.localizedDescription)")
        }
    }
    #endif

    private func writeSnapshot(_ state: PlaybackActivityAttributes.ContentState) {
        #if os(iOS)
        guard let group = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Self.appGroupIdentifier
        ) else { return }
        let dir = group.appendingPathComponent("Auralis", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("playback-snapshot.json")
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: url, options: .atomic)
        }
        #endif
    }

    private func clearSnapshot() {
        #if os(iOS)
        guard let group = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Self.appGroupIdentifier
        ) else { return }
        let url = group.appendingPathComponent(Self.snapshotRelativePath)
        try? FileManager.default.removeItem(at: url)
        #endif
    }
}

#if os(iOS)
/// 不变句柄：把非 Sendable 的 Activity 装进 @unchecked Sendable 盒子，
/// 以便在 nonisolated async 调用中传递，同时不暴露任何可变状态。
private final class LiveActivityHandle: @unchecked Sendable {
    let activity: Activity<PlaybackActivityAttributes>
    init(_ activity: Activity<PlaybackActivityAttributes>) {
        self.activity = activity
    }
}
#endif
