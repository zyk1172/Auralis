@testable import AppShell
import Foundation
import Testing

/// 首页与侧边栏栏目切割（用户要求：侧边栏已有的栏目不放首页；
/// 首页只保留适合首页的卡片货架，资料库入口由侧边栏承担）。
@Suite("Mac home sections")
struct MacHomeSectionsTests {
    @MainActor
    @Test("首页货架由内容模块默认顺序驱动")
    func homeShelfOrder() {
        // 标题已本地化（en: Random/Downloads 等），此处仅校验内容模块的 ID 顺序与数量，不依赖具体语言
        let ids = HomeModuleRegistry.modules(in: .content).map(\.id)
        #expect(ids == [.random, .recentlyPlayed, .longUnplayed, .recentlyAdded, .favoriteRandom, .downloads, .neverPlayed, .topArtists, .topAlbums])
        #expect(MacHomeView.shelfTitles.count == 9)
        // 同时校验旧的中文标题在任一语言下仍能通过本地化正确解析（至少包含随机音乐/Random 之一）
        let first = MacHomeView.shelfTitles.first ?? ""
        #expect(first == "随机音乐" || first == "Random", "首个货架标题应为随机音乐/Random，实际为 \(first)")
    }

    @MainActor
    @Test("首页不包含侧边栏资料库入口")
    func homeExcludesSidebarOnlySections() {
        for title in MacHomeView.sidebarOnlyTitles {
            #expect(!MacHomeView.shelfTitles.contains(title), "首页不应出现「\(title)」（侧边栏已承担）")
        }
    }

    @Test("Mac 首页按持久化顺序渲染，隐藏模块不因无数据改变偏好")
    func homeRendererUsesLayoutOrderAndVisibility() {
        let preferences = [
            HomeModulePreference(moduleID: "topAlbums", isVisible: true, order: 0),
            HomeModulePreference(moduleID: "random", isVisible: false, order: 1),
            HomeModulePreference(moduleID: "recentlyPlayed", isVisible: true, order: 2),
        ]
        let rendered = MacHomeView.renderedContentModuleIDs(
            preferences: preferences,
            available: [.topAlbums, .random, .recentlyPlayed]
        )
        #expect(rendered == ["topAlbums", "recentlyPlayed"])
        #expect(preferences[1].isVisible == false)
    }
}
