import Domain
import Intents
import LocalCatalog

/// 处理 Siri 的「播放音乐 / 播放某首歌」请求（INPlayMediaIntent）。
///
/// 本扩展运行在独立进程，无法直接驱动主 App 的播放引擎（AVPlayer / 音频会话都在主 App 内），
/// 因此：
/// 1. `resolveMediaItems` 直接读取 **App Group 共享的本地资料库**（SQLite），返回真实媒体项，
///    每个媒体项的 identifier 为「服务器ID:歌曲ID」，Siri 因此能展示准确的歌曲名称并精确匹配。
/// 2. `handle` 返回 `.continueInApp`，把含精确 GlobalID 的意图交回主 App；
///    主 App 在 `onContinueUserActivity` 中按 GlobalID 精确播放（不依赖文本猜测）。
final class IntentHandler: INExtension, INPlayMediaIntentHandling {
    override func handler(for intent: INIntent) -> Any {
        return self
    }

    // MARK: - INPlayMediaIntentHandling

    func handle(intent: INPlayMediaIntent, completion: @escaping (INPlayMediaIntentResponse) -> Void) {
        // 让系统拉起 Auralis，并把 INPlayMediaIntent（含精确 GlobalID 的 mediaItems）交给 App。
        let response = INPlayMediaIntentResponse(code: .continueInApp, userActivity: nil)
        completion(response)
    }

    func resolveMediaItems(
        for intent: INPlayMediaIntent,
        with completion: @escaping ([INPlayMediaMediaItemResolutionResult]) -> Void
    ) {
        // 没有具体查询（如「播放音乐」）：交给 App 决定。
        guard let query = intent.mediaSearch?.mediaName, !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            completion([.unsupported()])
            return
        }
        let items = Self.searchBlocking(query: query)
        if items.isEmpty {
            completion([.unsupported()])
        } else {
            completion(items.map { .success(with: $0) })
        }
    }

    func resolveResumePlayback(
        for intent: INPlayMediaIntent,
        with completion: @escaping (INBooleanResolutionResult) -> Void
    ) {
        // 让 Siri 直接开始播放，而不是只「恢复」已暂停的会话。
        completion(.success(with: false))
    }

    func resolvePlaybackQueueLocation(
        for intent: INPlayMediaIntent,
        with completion: @escaping (INPlaybackQueueLocationResolutionResult) -> Void
    ) {
        completion(.success(with: .now))
    }

    // MARK: - 本地资料库检索（App Group 共享）

    /// 阻塞式本地检索（扩展进程内短查询，避免把非 Sendable 闭包传入 Task）。
    private static func searchBlocking(query: String) -> [INMediaItem] {
        guard let store = sharedStore() else { return [] }
        let semaphore = DispatchSemaphore(value: 0)
        let box = SearchBox()
        Task {
            let summaries = (try? await store.searchTracks(query: query)) ?? []
            box.items = summaries.prefix(20).map { summary in
                INMediaItem(
                    identifier: summary.globalID.description,
                    title: summary.title,
                    type: .song,
                    artwork: nil
                )
            }
            semaphore.signal()
        }
        // 带超时的等待：SQLite 慢查询/锁竞争时最多等 5 秒，超时返回 []（调用方会返回 .unsupported()）（P2-8）。
        guard semaphore.wait(timeout: .now() + 5) == .success else { return [] }
        return box.items
    }

    private final class SearchBox: @unchecked Sendable {
        var items: [INMediaItem] = []
    }

    private static func sharedStore() -> LocalCatalogStore? {
        guard let group = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.auralis.player"
        ) else { return nil }
        let dir = group.appendingPathComponent("Auralis", isDirectory: true)
        return try? LocalCatalogStore(url: dir.appendingPathComponent("catalog.sqlite"))
    }
}
