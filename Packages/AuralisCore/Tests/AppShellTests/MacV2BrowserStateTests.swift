@testable import AppShell
import Domain
import LocalCatalog
import Testing

@Suite("Mac V2 category browser state")
struct MacV2BrowserStateTests {
    @Test("数据源替换时，不存在的分类选择会先清空")
    func categorySelectionClearsBeforeReplacement() {
        #expect(MacV2BrowserState.selectionAfterReplacing(
            selectedID: "mood:deep-night",
            availableIDs: ["mood:calm"]
        ) == nil)
        #expect(MacV2BrowserState.selectionAfterReplacing(
            selectedID: "mood:calm",
            availableIDs: ["mood:calm"]
        ) == "mood:calm")
    }

    @Test("陈旧分类请求不会覆盖当前维度或服务器")
    func staleTrackRequestIsRejected() {
        #expect(!MacV2BrowserState.acceptsTrackResult(
            expectedCategoryID: "mood:calm",
            selectedCategoryID: "mood:bright",
            expectedServerID: "server-a",
            activeServerID: "server-a",
            isCancelled: false
        ))
        #expect(!MacV2BrowserState.acceptsTrackResult(
            expectedCategoryID: "mood:calm",
            selectedCategoryID: "mood:calm",
            expectedServerID: "server-a",
            activeServerID: "server-b",
            isCancelled: false
        ))
        #expect(MacV2BrowserState.acceptsTrackResult(
            expectedCategoryID: "mood:calm",
            selectedCategoryID: "mood:calm",
            expectedServerID: "server-a",
            activeServerID: "server-a",
            isCancelled: false
        ))
    }

    @Test("列表替换后仅保留仍然存在的 GlobalID 选择")
    func tableSelectionIsCleanedAfterReplacement() {
        let keep = GlobalID(serverID: "server", remoteID: "keep")
        let stale = GlobalID(serverID: "server", remoteID: "stale")
        #expect(MacV2BrowserState.cleanedSelection([keep, stale], validTrackIDs: [keep]) == [keep])
    }

    @Test("分类按歌曲数量降序，数量相同保持稳定顺序")
    func categoriesAreSortedByTrackCount() {
        let categories = [
            RecommendationIndexV2Category(dimension: "scene", value: "通勤", trackCount: 3),
            RecommendationIndexV2Category(dimension: "mood", value: "明亮", trackCount: 9),
            RecommendationIndexV2Category(dimension: "mood", value: "平静", trackCount: 3),
        ]

        #expect(MacV2BrowserState.categoriesSortedByTrackCount(categories).map(\.id) == [
            "mood:明亮", "mood:平静", "scene:通勤",
        ])
    }

    @Test("快速切换分类时，旧状态不会重新成为有效选择")
    func rapidCategorySwitchesStayConsistent() {
        var selectedID: String? = "mood:平静"
        for index in 0..<100 {
            let replacementID = index.isMultiple(of: 2) ? "mood:激昂" : "scene:通勤"
            selectedID = MacV2BrowserState.selectionAfterReplacing(
                selectedID: selectedID,
                availableIDs: [replacementID]
            )
            #expect(selectedID == nil)
            selectedID = replacementID
        }
    }
}
