import Domain
import Foundation

/// 将结构化歌词的时间轴转换成可快速查询的原始行索引。
/// 时间轴在歌词加载完成时构建一次，播放过程中只进行二分查找。
enum LyricsIndexResolver {
    struct TimedLine: Equatable, Sendable {
        let index: Int
        let startTime: TimeInterval
    }

    static func timeline(for lines: [TimedLyricLine]) -> [TimedLine] {
        lines.enumerated().compactMap { index, line in
            guard let startTime = line.startTime else { return nil }
            return TimedLine(index: index, startTime: startTime)
        }
    }

    static func index(at position: TimeInterval, in timeline: [TimedLine], leadTime: TimeInterval = 0) -> Int? {
        guard !timeline.isEmpty else { return nil }

        let target = position + max(0, leadTime)
        var low = 0
        var high = timeline.count
        while low < high {
            let middle = (low + high) / 2
            if timeline[middle].startTime <= target {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low == 0 ? nil : timeline[low - 1].index
    }
}
