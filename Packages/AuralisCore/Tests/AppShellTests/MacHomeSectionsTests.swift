@testable import AppShell
import Foundation
import Testing

/// 首页与侧边栏栏目切割（用户要求：侧边栏已有的栏目不放首页；
/// 首页只保留适合首页的卡片货架，资料库入口由侧边栏承担）。
@Suite("Mac home sections")
struct MacHomeSectionsTests {
    @Test("首页货架顺序固定")
    func homeShelfOrder() {
        #expect(MacHomeView.shelfTitles == [
            "最近播放专辑",
            "最近添加专辑",
            "常听专辑",
            "常听艺术家",
            "很久没听",
            "从未播放",
            "收藏里随便听",
        ])
    }

    @Test("首页不包含侧边栏资料库入口")
    func homeExcludesSidebarOnlySections() {
        for title in MacHomeView.sidebarOnlyTitles {
            #expect(!MacHomeView.shelfTitles.contains(title), "首页不应出现「\(title)」（侧边栏已承担）")
        }
    }
}
