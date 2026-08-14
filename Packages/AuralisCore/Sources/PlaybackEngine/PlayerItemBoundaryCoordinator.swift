import Foundation

/// 播放边界确定性状态机（纯逻辑，可脱离 AVFoundation 独立测试）。
///
/// AVQueuePlayer 的「当前曲目播完」事件（AVPlayerItemDidPlayToEndTime）与
/// 「currentItem 变化」事件（KVO）到达顺序不确定：旧实现用一次 Task.yield 猜
/// currentItem 是否已推进，导致真实设备上循环/无缝切换不可靠（双重推进或漏推进）。
///
/// 本协调器把两个事件统一为明确的边界状态：
/// - idle：没有待决边界；
/// - waitingForPreparedAdvance：上一首已结束、正在等待 preloaded item 成为 current。
///
/// 同一歌曲边界只会产生一次 `.completeTransition` 或一次 `.handleTrackEnded`，
/// 不会两者都发生；fallback 有界、可取消、可去重。
public struct PlayerItemBoundaryCoordinator: Sendable {
    public enum Action: Equatable, Sendable {
        /// prepared item 已成为 current：完成无缝过渡（同一边界只会输出一次）。
        case completeTransition
        /// 当前曲目自然结束且无有效预载（或预载失败/超时）：交由上层决定下一步。
        case handleTrackEnded
        /// 从队列移除失效的 prepared item。
        case removePrepared
    }

    public enum State: Equatable, Sendable {
        case idle
        case waitingForPreparedAdvance
    }

    public private(set) var state: State = .idle

    public init() {}

    /// 事件：当前 item 播完（DidPlayToEnd）。
    /// - hasPrepared: 队列中是否存在可推进的 prepared item。
    /// - currentItemIsPrepared: 此刻 currentItem 是否已经是该 prepared item
    ///   （E2 先于 E1 到达时成立，此时可直接完成过渡）。
    public mutating func itemEnded(hasPrepared: Bool, currentItemIsPrepared: Bool) -> [Action] {
        // 去重：同一结束事件只处理一次。
        if state == .waitingForPreparedAdvance { return [] }
        if hasPrepared {
            if currentItemIsPrepared {
                // 推进已发生：直接完成过渡，不再等 KVO。
                state = .idle
                return [.completeTransition]
            }
            state = .waitingForPreparedAdvance
            return []
        }
        // 无预载项：自然结束，交由上层决定 repeat/shuffle 策略。
        return [.handleTrackEnded]
    }

    /// 事件：AVQueuePlayer.currentItem KVO 变化。
    /// - newItemIsPrepared: 新 current 是否为待决的 prepared item。
    public mutating func currentItemChanged(newItemIsPrepared: Bool) -> [Action] {
        guard state == .waitingForPreparedAdvance else { return [] }
        guard newItemIsPrepared else { return [] }
        state = .idle
        return [.completeTransition]
    }

    /// 事件：prepared item 在真正推进前失败。
    /// 返回 [.removePrepared]；若当时正在等待该 item 推进（上一首已结束），
    /// 额外返回 [.handleTrackEnded] 作为「未推进」兜底（只一次）。
    public mutating func preparedFailed() -> [Action] {
        if state == .waitingForPreparedAdvance {
            state = .idle
            return [.removePrepared, .handleTrackEnded]
        }
        return [.removePrepared]
    }

    /// 事件：等待推进超时（有界兜底）。仍在等待才处理；只输出一次。
    public mutating func fallbackTick() -> [Action] {
        guard state == .waitingForPreparedAdvance else { return [] }
        state = .idle
        return [.removePrepared, .handleTrackEnded]
    }

    public mutating func reset() {
        state = .idle
    }
}
