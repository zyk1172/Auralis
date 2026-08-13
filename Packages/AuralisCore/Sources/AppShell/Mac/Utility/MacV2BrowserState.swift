#if os(macOS)
import Domain
import LocalCatalog

/// V2 分类浏览器的可测试状态规则。
/// View 只保存渲染状态；此处集中处理数据替换、陈旧异步结果和表格选择的完整性约束。
enum MacV2BrowserState {
    static func selectionAfterReplacing(
        selectedID: String?,
        availableIDs: Set<String>
    ) -> String? {
        guard let selectedID, availableIDs.contains(selectedID) else { return nil }
        return selectedID
    }

    static func acceptsTrackResult(
        expectedCategoryID: String,
        selectedCategoryID: String?,
        expectedServerID: ServerID,
        activeServerID: ServerID?,
        isCancelled: Bool
    ) -> Bool {
        !isCancelled && selectedCategoryID == expectedCategoryID && activeServerID == expectedServerID
    }

    static func cleanedSelection(_ selection: Set<GlobalID>, validTrackIDs: Set<GlobalID>) -> Set<GlobalID> {
        selection.intersection(validTrackIDs)
    }
}
#endif
