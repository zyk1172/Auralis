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
}
