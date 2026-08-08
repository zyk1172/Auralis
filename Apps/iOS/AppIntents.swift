import AppIntents
import AppShell
import Foundation

/// 快捷指令 App 中可见的常用播放操作。
/// 所有意图都通过 AuralisAppModel.shared 落到与界面同一个播放服务，
/// 避免维护多套不一致的播放器状态。
struct AuralisAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AuralisAskAssistantIntent(),
            phrases: [
                "\(.applicationName) 让 AI 助手操作",
                "\(.applicationName) 问 AI 助手",
                "\(.applicationName) 帮我操作音乐",
            ],
            shortTitle: "问 AI 助手",
            systemImageName: "sparkles"
        )
        AppShortcut(
            intent: AuralisPlayPauseIntent(),
            phrases: [
                "\(.applicationName) 播放或暂停",
                "\(.applicationName) 播放音乐",
                "\(.applicationName) 继续播放",
            ],
            shortTitle: "播放或暂停",
            systemImageName: "playpause.fill"
        )
        AppShortcut(
            intent: AuralisNextTrackIntent(),
            phrases: ["\(.applicationName) 下一首"],
            shortTitle: "下一首",
            systemImageName: "forward.fill"
        )
        AppShortcut(
            intent: AuralisPreviousTrackIntent(),
            phrases: ["\(.applicationName) 上一首"],
            shortTitle: "上一首",
            systemImageName: "backward.fill"
        )
        AppShortcut(
            intent: AuralisPlayFavoritesIntent(),
            phrases: ["\(.applicationName) 播放我的收藏"],
            shortTitle: "播放我的收藏",
            systemImageName: "heart.fill"
        )
        AppShortcut(
            intent: AuralisPlayRecentIntent(),
            phrases: ["\(.applicationName) 播放最近听过的音乐"],
            shortTitle: "播放最近听过的音乐",
            systemImageName: "clock.fill"
        )
        AppShortcut(
            intent: AuralisPlayRandomIntent(),
            phrases: ["\(.applicationName) 播放随机音乐"],
            shortTitle: "播放随机音乐",
            systemImageName: "shuffle"
        )
        AppShortcut(
            intent: AuralisPlaySongIntent(),
            phrases: ["\(.applicationName) 播放歌曲"],
            shortTitle: "播放歌曲",
            systemImageName: "music.note"
        )
        AppShortcut(
            intent: AuralisSetSleepTimerIntent(),
            phrases: ["\(.applicationName) 设置睡眠定时"],
            shortTitle: "设置睡眠定时",
            systemImageName: "moon.zzz.fill"
        )
        AppShortcut(
            intent: AuralisSyncLibraryIntent(),
            phrases: ["\(.applicationName) 同步音乐库"],
            shortTitle: "同步音乐库",
            systemImageName: "arrow.triangle.2.circlepath"
        )
    }
}

/// 播放 / 暂停（在播放与暂停之间切换）。
struct AuralisPlayPauseIntent: AppIntent {
    static let title: LocalizedStringResource = "播放或暂停"
    static let description = IntentDescription("播放或暂停 Auralis 的音乐")

    @MainActor
    func perform() async throws -> some IntentResult {
        AuralisAppModel.shared.togglePlayback()
        return .result()
    }
}

/// 下一首。
struct AuralisNextTrackIntent: AppIntent {
    static let title: LocalizedStringResource = "下一首"
    static let description = IntentDescription("播放队列中的下一首歌曲")

    @MainActor
    func perform() async throws -> some IntentResult {
        AuralisAppModel.shared.next()
        return .result()
    }
}

/// 上一首。
struct AuralisPreviousTrackIntent: AppIntent {
    static let title: LocalizedStringResource = "上一首"
    static let description = IntentDescription("播放队列中的上一首歌曲")

    @MainActor
    func perform() async throws -> some IntentResult {
        AuralisAppModel.shared.previous()
        return .result()
    }
}

/// 播放收藏。
struct AuralisPlayFavoritesIntent: AppIntent {
    static let title: LocalizedStringResource = "播放我的收藏"
    static let description = IntentDescription("播放我收藏的歌曲")

    @MainActor
    func perform() async throws -> some IntentResult {
        AuralisAppModel.shared.handlePlaybackCommand("播放我的收藏")
        return .result()
    }
}

/// 播放最近听过的音乐。
struct AuralisPlayRecentIntent: AppIntent {
    static let title: LocalizedStringResource = "播放最近听过的音乐"
    static let description = IntentDescription("播放最近听过的歌曲")

    @MainActor
    func perform() async throws -> some IntentResult {
        AuralisAppModel.shared.handlePlaybackCommand("播放最近听过的音乐")
        return .result()
    }
}

/// 播放随机音乐。
struct AuralisPlayRandomIntent: AppIntent {
    static let title: LocalizedStringResource = "播放随机音乐"
    static let description = IntentDescription("随机播放资料库中的歌曲")

    @MainActor
    func perform() async throws -> some IntentResult {
        AuralisAppModel.shared.handlePlaybackCommand("播放随机音乐")
        return .result()
    }
}

/// 切换随机播放。
struct AuralisToggleShuffleIntent: AppIntent {
    static let title: LocalizedStringResource = "切换随机播放"
    static let description = IntentDescription("开启或关闭随机播放")

    @MainActor
    func perform() async throws -> some IntentResult {
        AuralisAppModel.shared.handlePlaybackCommand("切换随机播放")
        return .result()
    }
}

/// 切换循环播放。
struct AuralisToggleRepeatIntent: AppIntent {
    static let title: LocalizedStringResource = "切换循环播放"
    static let description = IntentDescription("开启或关闭循环播放")

    @MainActor
    func perform() async throws -> some IntentResult {
        AuralisAppModel.shared.handlePlaybackCommand("切换循环播放")
        return .result()
    }
}

/// 播放指定歌曲。
struct AuralisPlaySongIntent: AppIntent {
    static let title: LocalizedStringResource = "播放歌曲"
    static let description = IntentDescription("用 Auralis 播放指定歌曲")

    @Parameter(title: "歌曲名称", requestValueDialog: "要播放哪首歌？")
    var song: String

    @MainActor
    func perform() async throws -> some IntentResult {
        AuralisAppModel.shared.handlePlaybackCommand("播放 \(song)")
        return .result()
    }
}


/// 设置睡眠定时（倒计时分钟）。
struct AuralisSetSleepTimerIntent: AppIntent {
    static let title: LocalizedStringResource = "设置睡眠定时"
    static let description = IntentDescription("设置几分钟后停止播放")

    @Parameter(title: "分钟", requestValueDialog: "几分钟后停止播放？")
    var minutes: Int

    @MainActor
    func perform() async throws -> some IntentResult {
        AuralisAppModel.shared.setSleepTimer(mode: .afterMinutes, minutes: TimeInterval(max(minutes, 1)))
        return .result()
    }
}

/// 同步音乐库（后台增量同步）。
struct AuralisSyncLibraryIntent: AppIntent {
    static let title: LocalizedStringResource = "同步音乐库"
    static let description = IntentDescription("从服务器增量同步本地音乐库")

    @MainActor
    func perform() async throws -> some IntentResult {
        await AuralisAppModel.shared.syncLibraryNow()
        return .result()
    }
}
