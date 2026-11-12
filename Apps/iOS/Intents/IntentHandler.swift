// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
import Domain
import Foundation
import Intents
import LocalCatalog
import os

/// 处理 Siri 的「播放音乐 / 播放某首歌」请求（INPlayMediaIntent）。
///
/// 本扩展运行在独立进程，无法直接驱动主 App 的播放引擎（AVPlayer / 音频会话都在主 App 内），
/// 因此：
/// 1. `resolveMediaItems` 直接读取 **App Group 共享的本地资料库**（SQLite），返回真实媒体项，
///    每个媒体项的 identifier 为「服务器ID:歌曲ID」，Siri 因此能展示准确的歌曲名称并精确匹配。
/// 2. `handle` 返回 `.continueInApp`，把含精确 GlobalID 的意图交回主 App；
///    主 App 在 `onContinueUserActivity` 中按 GlobalID 精确播放（不依赖文本猜测）。
///
/// 关于 `.continueInApp`：媒体播放必须发生在持有 AVPlayer 与音频会话的主 App 内，
/// 扩展没有播放能力，也不应维护第二套播放状态。Apple 的响应约定是——返回
/// `.continueInApp` 时系统会拉起 App，并把 `interaction` 为本次意图的 `NSUserActivity`
/// 交给 App（见 INPlayMediaIntentResponse 头文件说明），因此这里传入 `userActivity: nil`
/// 是受支持的用法，系统会自行构造该 activity。
final class IntentHandler: INExtension, INPlayMediaIntentHandling {
    /// 无具体查询（「播放音乐」）时的占位媒体项标识。
    /// 与 `AuralisAppModel.handleSiriUserActivity` 共用；不是 GlobalID，不含冒号。
    static let playAllIdentifier = SiriMediaIdentifier.playAll

    private static let log = Logger(subsystem: "com.auralis.player.ios", category: "siri-intents")

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
        // 没有具体查询（如「用 Auralis 播放音乐」）：返回一个「播放全部」占位项。
        // 早期实现直接返回 .unsupported()，等于告诉 Siri「这个 App 播不了」，
        // 于是媒体域在解析阶段就放弃 Auralis——即使 App 已经出现在候选列表里。
        guard let rawQuery = intent.mediaSearch?.mediaName,
              !rawQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            Self.log.info("Siri 媒体解析：无具体查询，返回 play-all 占位项")
            let item = INMediaItem(
                identifier: Self.playAllIdentifier,
                title: nil,
                type: .music,
                artwork: nil
            )
            completion([.success(with: item)])
            return
        }

        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let items = Self.searchBlocking(query: query)
        guard !items.isEmpty else {
            // App Group 不可用或资料库确实没有匹配项。两者都如实回报「不支持」，
            // 不能假装成功——否则 Siri 会宣布正在播放而实际没有任何声音。
            Self.log.error("Siri 媒体解析：query=\(query, privacy: .public) 无匹配项（共享资料库不可用或为空）")
            completion([.unsupported()])
            return
        }
        Self.log.info("Siri 媒体解析：query=\(query, privacy: .public) 命中 \(items.count) 项")
        completion(items.map { .success(with: $0) })
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
        guard semaphore.wait(timeout: .now() + 5) == .success else {
            log.error("Siri 媒体解析：共享资料库查询超过 5 秒未返回")
            return []
        }
        return box.items
    }

    private final class SearchBox: @unchecked Sendable {
        var items: [INMediaItem] = []
    }

    /// 打开 App Group 共享资料库。
    ///
    /// 显式检查 App Group 容器：`LocalCatalogStore.defaultStoreURL` 在容器不可用时会
    /// 静默回退到扩展自己的沙盒目录（必然是个空库），对 Siri 而言表现为「搜索不到」，
    /// 但真实原因是签名缺少 App Group 授权。这里先判定容器，缺失时明确记录日志。
    private static func sharedStore() -> LocalCatalogStore? {
        let groupIdentifier = "group.com.auralis.player"
        guard FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: groupIdentifier
        ) != nil else {
            log.error("Siri 媒体解析：App Group \(groupIdentifier, privacy: .public) 不可用，无法读取共享资料库（检查签名授权）")
            return nil
        }
        let url = LocalCatalogStore.defaultStoreURL(appGroupIdentifier: groupIdentifier)
        do {
            return try LocalCatalogStore(url: url)
        } catch {
            log.error("Siri 媒体解析：打开共享资料库失败 \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}
