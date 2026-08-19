import Foundation

/// 首页模块分组：快捷入口与内容模块分开排序、分开显示/隐藏（互不混排）。
public enum HomeModuleGroup: String, Codable, Sendable, CaseIterable {
    case quickEntry
    case content

    public var title: String {
        switch self {
        case .quickEntry: String(localized: "快捷入口", bundle: .module)
        case .content: String(localized: "内容模块", bundle: .module)
        }
    }
}

/// 首页模块 ID。以后新增模块只需在注册表（HomeModuleRegistry）里加一项、
/// 在 AuralisAppModel 提供数据快照、在 HomeView 提供对应视图即可，
/// 不再出现 `if showX` 写死分支。
public enum HomeModuleID: String, Codable, Sendable, CaseIterable, Identifiable {
    // 快捷入口
    case playlists
    case favorites
    case mostPlayed
    case playHistory
    case downloads
    // 内容模块
    case random
    case recentlyPlayed
    case recentlyAdded
    case longUnplayed
    case favoriteRandom
    case neverPlayed
    case topArtists
    case topAlbums

    public var id: String { rawValue }
}

/// 首页模块的静态注册信息：ID / 分组 / 标题 / 图标 / 默认可见 / 默认顺序。
/// 只描述「有哪些模块、默认长什么样」，不含任何数据访问。
public struct HomeModule: Identifiable, Sendable {
    public let id: HomeModuleID
    public let group: HomeModuleGroup
    public let title: String
    public let icon: String
    public let defaultVisible: Bool
    public let defaultOrder: Int

    public init(
        id: HomeModuleID,
        group: HomeModuleGroup,
        title: String,
        icon: String,
        defaultVisible: Bool,
        defaultOrder: Int
    ) {
        self.id = id
        self.group = group
        self.title = title
        self.icon = icon
        self.defaultVisible = defaultVisible
        self.defaultOrder = defaultOrder
    }
}

/// 首页模块注册表：所有可选模块的唯一来源。
/// 默认配置（首次安装 / 无配置时）：
/// - 快捷入口仅 歌单 / 收藏 / 最常听（不提供播放历史）。
/// - 内容模块默认 随机音乐 / 最近播放 / 很久没听 / 最近添加 / 收藏里随便听 / 下载；
///   默认隐藏 从未播放 / 常听艺术家 / 常听专辑。
public enum HomeModuleRegistry {
    public static let allModules: [HomeModule] = {
        var modules: [HomeModule] = []
        // 快捷入口（默认顺序 0...4）
        modules.append(HomeModule(
            id: .playlists, group: .quickEntry,
            title: String(localized: "歌单", bundle: .module), icon: "music.note.list",
            defaultVisible: true, defaultOrder: 0
        ))
        modules.append(HomeModule(
            id: .favorites, group: .quickEntry,
            title: String(localized: "收藏", bundle: .module), icon: "heart.fill",
            defaultVisible: true, defaultOrder: 1
        ))
        modules.append(HomeModule(
            id: .mostPlayed, group: .quickEntry,
            title: String(localized: "最常听", bundle: .module), icon: "play.circle.fill",
            defaultVisible: true, defaultOrder: 2
        ))
        // 快捷入口仅保留 歌单/收藏/最常听（一行 3 个，超过自动换行，不做横向滚动）。
        // 内容模块默认顺序 0...8。
        modules.append(HomeModule(
            id: .random, group: .content,
            title: String(localized: "随机音乐", bundle: .module), icon: "shuffle",
            defaultVisible: true, defaultOrder: 0
        ))
        modules.append(HomeModule(
            id: .recentlyPlayed, group: .content,
            title: String(localized: "最近播放", bundle: .module), icon: "clock.fill",
            defaultVisible: true, defaultOrder: 1
        ))
        modules.append(HomeModule(
            id: .longUnplayed, group: .content,
            title: String(localized: "很久没听", bundle: .module), icon: "moon.zzz.fill",
            defaultVisible: true, defaultOrder: 2
        ))
        modules.append(HomeModule(
            id: .recentlyAdded, group: .content,
            title: String(localized: "最近添加", bundle: .module), icon: "plus.circle.fill",
            defaultVisible: true, defaultOrder: 3
        ))
        modules.append(HomeModule(
            id: .favoriteRandom, group: .content,
            title: String(localized: "收藏里随便听", bundle: .module), icon: "heart.text.square.fill",
            defaultVisible: true, defaultOrder: 4
        ))
        modules.append(HomeModule(
            id: .downloads, group: .content,
            title: String(localized: "下载", bundle: .module), icon: "arrow.down.circle.fill",
            defaultVisible: true, defaultOrder: 5
        ))
        modules.append(HomeModule(
            id: .neverPlayed, group: .content,
            title: String(localized: "从未播放", bundle: .module), icon: "music.note.house.fill",
            defaultVisible: false, defaultOrder: 6
        ))
        modules.append(HomeModule(
            id: .topArtists, group: .content,
            title: String(localized: "常听艺术家", bundle: .module), icon: "person.crop.rectangle.stack.fill",
            defaultVisible: false, defaultOrder: 7
        ))
        modules.append(HomeModule(
            id: .topAlbums, group: .content,
            title: String(localized: "常听专辑", bundle: .module), icon: "square.stack.fill",
            defaultVisible: false, defaultOrder: 8
        ))
        return modules
    }()

    /// 按分组取模块（按默认顺序排序）。
    public static func modules(in group: HomeModuleGroup) -> [HomeModule] {
        allModules
            .filter { $0.group == group }
            .sorted { $0.defaultOrder < $1.defaultOrder }
    }

    /// 按字符串 ID 查模块；未知 ID 返回 nil（旧版本遗留的无效 ID 由 HomeLayoutStore 归一化时丢弃）。
    public static func module(forID id: String) -> HomeModule? {
        allModules.first { $0.id.rawValue == id }
    }

    /// 默认布局偏好（首次安装 / 恢复默认时使用）。
    public static func defaultPreference() -> HomeLayoutPreference {
        HomeLayoutPreference(
            quickEntries: modules(in: .quickEntry).map {
                HomeModulePreference(moduleID: $0.id.rawValue, isVisible: $0.defaultVisible, order: $0.defaultOrder)
            },
            contentModules: modules(in: .content).map {
                HomeModulePreference(moduleID: $0.id.rawValue, isVisible: $0.defaultVisible, order: $0.defaultOrder)
            }
        )
    }
}