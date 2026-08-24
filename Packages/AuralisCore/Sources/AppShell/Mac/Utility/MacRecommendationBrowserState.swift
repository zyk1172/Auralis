#if os(macOS)
import Domain
import Foundation
import LocalCatalog

/// V2 分类浏览器的可测试状态规则。
/// View 只保存渲染状态；此处集中处理数据替换、陈旧异步结果和表格选择的完整性约束。
enum MacV2BrowserState {
    /// 分类页的视觉顺序以实际歌曲数为准；同数量时按稳定身份排序，保证刷新不跳动。
    static func categoriesSortedByTrackCount(_ categories: [RecommendationIndexV2Category]) -> [RecommendationIndexV2Category] {
        categories.sorted { left, right in
            if left.trackCount != right.trackCount { return left.trackCount > right.trackCount }
            return left.id.localizedStandardCompare(right.id) == .orderedAscending
        }
    }

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