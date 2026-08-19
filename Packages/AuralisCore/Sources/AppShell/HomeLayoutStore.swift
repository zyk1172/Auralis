import Foundation

/// 单个首页模块的布局偏好：是否显示 + 排序。
/// `order` 只是持久化快照字段（写盘时重写为数组下标）；运行期以数组顺序为权威。
public struct HomeModulePreference: Codable, Equatable, Identifiable, Sendable {
    public let moduleID: String
    public var isVisible: Bool
    public var order: Int

    public init(moduleID: String, isVisible: Bool, order: Int) {
        self.moduleID = moduleID
        self.isVisible = isVisible
        self.order = order
    }

    public var id: String { moduleID }
}

/// 首页完整布局偏好：快捷入口与内容模块分开存储、分开排序。
public struct HomeLayoutPreference: Codable, Equatable, Sendable {
    public var quickEntries: [HomeModulePreference]
    public var contentModules: [HomeModulePreference]

    public init(quickEntries: [HomeModulePreference], contentModules: [HomeModulePreference]) {
        self.quickEntries = quickEntries
        self.contentModules = contentModules
    }

    /// 取某分组下的偏好列表（数组顺序即展示顺序）。
    public func preferences(in group: HomeModuleGroup) -> [HomeModulePreference] {
        switch group {
        case .quickEntry: quickEntries
        case .content: contentModules
        }
    }

    /// 按模块 ID 查偏好（两个分组都会查）。
    public func preference(moduleID: String) -> HomeModulePreference? {
        quickEntries.first { $0.moduleID == moduleID }
            ?? contentModules.first { $0.moduleID == moduleID }
    }
}

/// 首页布局偏好的 UserDefaults 读写。
/// 只读写布局偏好键，绝不触碰任何歌曲数据 / 缓存 / 播放记录 / 收藏。
public enum HomeLayoutStore {
    public static let defaultsKey = "auralis.homeLayout.v1"

    /// 读取布局偏好；无配置时返回默认布局。读取时做归一化（见 `normalized`）。
    public static func load(from defaults: UserDefaults) -> HomeLayoutPreference {
        guard let data = defaults.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode(HomeLayoutPreference.self, from: data)
        else {
            return HomeModuleRegistry.defaultPreference()
        }
        return normalized(decoded)
    }

    /// 保存布局偏好（写盘前归一化）。
    public static func save(_ preference: HomeLayoutPreference, to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(normalized(preference)) else { return }
        defaults.set(data, forKey: defaultsKey)
    }

    /// 归一化：
    /// 1. 以数组顺序为权威，重写每个模块的 order 字段（数组下标）；
    /// 2. 丢弃未知 / 重复模块 ID（旧版本遗留数据不会污染新首页）；
    /// 3. 补齐注册表里有、但旧配置里没有的新模块（按默认设置追加到末尾），
    ///    保证「以后新增模块只需注册」对已装用户也成立。
    public static func normalized(_ preference: HomeLayoutPreference) -> HomeLayoutPreference {
        func normalize(_ list: [HomeModulePreference], in group: HomeModuleGroup) -> [HomeModulePreference] {
            let registryModules = HomeModuleRegistry.modules(in: group)
            var seen = Set<String>()
            var result: [HomeModulePreference] = []
            for item in list {
                guard registryModules.contains(where: { $0.id.rawValue == item.moduleID }),
                      seen.insert(item.moduleID).inserted
                else { continue }
                result.append(HomeModulePreference(
                    moduleID: item.moduleID,
                    isVisible: item.isVisible,
                    order: result.count
                ))
            }
            for module in registryModules where !seen.contains(module.id.rawValue) {
                result.append(HomeModulePreference(
                    moduleID: module.id.rawValue,
                    isVisible: module.defaultVisible,
                    order: result.count
                ))
            }
            return result
        }
        return HomeLayoutPreference(
            quickEntries: normalize(preference.quickEntries, in: .quickEntry),
            contentModules: normalize(preference.contentModules, in: .content)
        )
    }
}