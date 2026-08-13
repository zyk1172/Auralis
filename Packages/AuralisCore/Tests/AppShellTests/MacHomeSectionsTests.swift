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
        #expect(MacHomeView.shelfTitles == [
            "随机音乐", "最近播放", "很久没听", "最近添加", "收藏里随便听",
            "从未播放", "常听艺术家", "常听专辑",
        ])
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
