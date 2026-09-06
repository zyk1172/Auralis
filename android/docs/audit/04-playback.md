# 04 - 播放引擎 / 队列 / ReplayGain 迁移规格报告

> 审计对象：Auralis（Swift / AVFoundation）播放层。目标：为 Android（Media3 / ExoPlayer）实现提供 1:1 规格。
> 只读审计，未修改任何文件。所有常量均逐字引用真实代码。

---

## 0. 关键结论速览（含窗口参数核对）

**用户猜测的窗口参数与真实代码完全一致，无差异：**

| 参数 | 用户猜测 | 真实代码常量 | 真实值 |
|------|---------|-------------|--------|
| threshold（进入窗口化队列的阈值） | 500 | `largeContextThreshold` | **500** |
| initial window（初始物化窗口大小） | 256 | `largeWindowInitial` | **256** |
| refill threshold（剩余 ≤ 触发补充） | 48 | `largeWindowRefillThreshold` | **48** |
| refill batch（每次补充批量） | 192 | `largeWindowRefillBatch` | **192** |

来源 `AuralisAppModel.swift:80-83`：

```swift
private let largeContextThreshold = 500
private let largeWindowInitial = 256
private let largeWindowRefillThreshold = 48
private let largeWindowRefillBatch = 192
```

另外需重点提示：**`PlaybackState` 没有 `ended` 状态**。自然播完不进入状态机，而是触发 `trackEndedHandler` 回调，由 `AppModel.handleTrackEnded()` 决定下一首/单曲循环/暂停。`failed` 携带 `PlaybackError` 关联值。

---

## 1. 状态机（PlaybackState）

### 1.1 枚举定义

`Domain/Models.swift`：

```swift
public enum PlaybackState: Codable, Hashable, Sendable {
    case idle
    case preparing
    case buffering
    case playing
    case paused
    case stalled
    case failed(PlaybackError)
}
```

`PlaybackError`（`Domain/Models.swift`）：`.networkUnavailable / .unsupportedFormat(String) / .authorizationFailed / .engineFailure(String)`。

### 1.2 状态迁移与各触发条件

引擎内部状态由 `AVFoundationPlaybackEngine.setPlaybackState(_:)` 维护（`AVFoundationPlaybackEngine.swift:564`）。**注意：`timingHandler` 仅在 buffering/playing/paused/stalled 触发，idle/preparing/failed 不触发**（`:566-573`）。

| 源状态 | 目标状态 | 触发条件（逐字/精确） |
|--------|---------|----------------------|
| — | `idle` | 初始值 `private var playbackState: PlaybackState = .idle`（`:14`）；`stop()` 后 `setPlaybackState(.idle)`（`:549`） |
| `idle`/`paused`/`playing`/`buffering`/`stalled` | `preparing` | `play(track:)` 开头 `setPlaybackState(.preparing)`（`:337`）；若 `track.streamURL == nil` 则直接 `.failed(.engineFailure("该歌曲没有可播放的地址"))`（`:344`） |
| `preparing` | `playing` | `player.play()` 成功且未请求暂停：`setPlaybackState(.playing)`（`:446`）。若 `pauseRequestedDuringPreparing` 为真 → `setPlaybackState(.paused)`（`:441`） |
| `preparing`/`buffering`/`playing`/`stalled` | `paused` | `pause()`：仅在 `preparing`（记录意图）或 `playing`/`buffering`/`stalled` 时生效（`:512-528`）。`resume()` 不会回到 paused |
| 任意非 paused | `buffering` | `timeControlStatus == .waitingToPlayAtSpecifiedRate` 且非 paused（`:942-945`）；`handleStreamFailure` 重试期间 `playbackState = .buffering`（`:5546`） |
| 任意非 paused/非 failed | `playing` | `timeControlStatus == .playing`（`:946-949`）；`resume()`（`:544`）；`finishPreparedTransition` 依据 `timeControlStatus`（`:855`） |
| 任意非 paused/非 failed | `stalled` | `AVPlayerItemPlaybackStalled` 通知（`:914-929`），且 `case .failed` 免疫、非 paused 才置 stalled 并 `startStallTimeout()` |
| 任意 | `failed(PlaybackError)` | `reportPlaybackFailure()`（`:987-997`）：item `status == .failed` 或 `FailedToPlayToEndTime` 通知（去重 `failureReported`）；或 `stalled` 超时 15s 未恢复。`play(track:)` 缺 streamURL 也置 failed |
| — | （无 `ended`） | 自然播完走 `AVPlayerItemDidPlayToEndTime` → `handleItemDidPlayToEnd` → `trackEndedHandler?()`，**不改变 `playbackState` 枚举**（见 §6） |

> 失败态免疫（`:923`、`:940`）：进入 `.failed` 后，晚到的 stall 通知 / `timeControlStatus` KVO 回调不得把状态改回 stalled/buffering/playing，避免“失败被掩盖”。

---

## 2. 队列架构（logical queue ↔ windowed presentation）

### 2.1 两层结构

- **Logical queue（逻辑队列，权威）**：`AuralisAppModel.largeLogicalContext: [Track]?`（`AuralisAppModel.swift:77`），保存完整曲目顺序。普通队列（≤500）直接用 `queueStore.tracks`（`:91-93`）。
- **Windowed presentation（窗口化展示）**：`PlaybackQueuePresentationStore.entries: [QueueEntry]`（`PlaybackQueuePresentationStore.swift:26`），首屏只物化最多 256 项供 SwiftUI 渲染与播放热路径。`QueueEntry.id` 为独立 UUID（R05：同一首歌允许多次出现，每次独立身份）。

### 2.2 真实常量（核对用户猜测）

```swift
// AuralisAppModel.swift:80-83
private let largeContextThreshold = 500          // 进入窗口化的逻辑队列大小阈值
private let largeWindowInitial = 256             // 初始物化窗口大小
private let largeWindowRefillThreshold = 48     // 当前项距窗口尾 ≤ 此值则补充
private let largeWindowRefillBatch = 192         // 每次补充批量
```

**结论：用户猜测值与实际代码逐一相等，无差异。**

### 2.3 窗口如何随下标滑动

**初始安装**（`installLargeLogicalContext`，`:116-130`）：

```swift
let start = preparedWindowStart.map {
    max(0, min($0, logical.count - 1))
} ?? max(0, min(clampedIndex - 64, logical.count - largeWindowInitial))
let end = min(start + largeWindowInitial, logical.count)
let window = Array(logical[start..<end])
...
largeLogicalWindowStart = start
largeLogicalNextIndex = end
```

即首次以「当前歌曲 - 64」居中、宽 256 开窗口（边界夹取）；`playTrack(_:in:)` 上下文播放时窗口从选中下标 `selIdx` 起、宽 256（`:2024-2026`，`end = min(start + 256, ...)`）。

**补充（前进时）**（`refillLargeWindowIfNeeded`，`:134-147`）：

```swift
let remaining = queueStore.count - (queueStore.currentIndex ?? -1) - 1
guard remaining <= largeWindowRefillThreshold else { return }
guard nextIdx < logical.count else { return }
let end = min(nextIdx + largeWindowRefillBatch, logical.count)
let batch = Array(logical[nextIdx..<end])
queueStore.append(batch, currentTrackID: queueIdentity(currentTrack))
largeLogicalNextIndex = end
```

即：当前项距窗口尾剩余项 ≤ 48 时，从 `largeLogicalNextIndex` 追加 192 首，`nextIdx` 前推。

**目标索引越界补充**（`ensureLargeWindowContains`，`:149-163`）：逻辑目标 ≥ 窗口尾时，循环按 192 批量追加直到覆盖目标。

**窗口重建（回退 / 跳转）**（`rebuildLargeWindow(around:)`，`:165-181`）：当前项离开窗口（如 previous 到窗口之前、shuffle 选到窗口外）时，以 `logicalIndex - 64` 居中重建 256 宽窗口，并精确按 logical occurrence（`selectedLocalIndex: logicalIndex - start`）选中，绝不按 GlobalID 反查第一个重复项（避免重复歌曲漂移）。

**逻辑↔窗口下标换算**（`AuralisAppModel.swift:85-88`）：

```swift
private var largeLogicalCurrentIndex: Int? {
    guard largeLogicalContext != nil, let start = largeLogicalWindowStart, let cur = queueStore.currentIndex else { return nil }
    return start + cur
}
```

### 2.4 性能约束

- 队列规模可达 10000+；重活（QueueEntry 创建 + 选曲 index + 持久化 ID + 索引字典）在后台 `Task.detached` 一次性完成（`prepare(...)` 为 `nonisolated static`，`:140`），MainActor 只 `installPreparedQueue` 赋值（`:194`），每次变更只 `objectWillChange.send()` 一次（`:96-104`）。
- 热路径禁止 `entries.map(\.track)`（`tracks` 全量快照仅兼容用，`:84`）；用 O(1) 的 `count`/`track(at:)`/`indexByEntryID`/`firstIndexByGlobalID`（`:44-45`、`52-70`）。

---

## 3. Previous / Next 语义

### 3.1 previous()（`AuralisAppModel.swift:4751`）

```swift
public func previous() {
    if playbackPosition > 3 {
        // 超过 3 秒：回到本曲开头——真实 seek 引擎（P2-10）
        seekToAbsolute(0)
        return
    }
    ...
    if let logical = largeLogicalContext, let lIdx = largeLogicalCurrentIndex {
        if lIdx > 0 {
            let target = lIdx - 1
            if let start = largeLogicalWindowStart, target < start {
                rebuildLargeWindow(around: target)          // 窗口外→重建并按 occurrence 选中
                selectAndPlay(logical[target], reconcileQueue: false)
                return
            }
            if let previous = queueStore.advanceBackward() {
                selectAndPlay(previous); return
            }
            selectAndPlay(logical[target]); return
        } else if repeatMode == .all, logical.count > 1 {
            let lastIdx = logical.count - 1                 // 队首 + 列表循环 → 绕回队尾
            rebuildLargeWindow(around: lastIdx)
            selectAndPlay(logical[lastIdx], reconcileQueue: false)
            return
        } else { seekToAbsolute(0); return }                // 第一首且无循环：回本曲开头
    }
    if let previous = queueStore.advanceBackward() {
        selectAndPlay(previous)
    } else if repeatMode == .all, let lastEntry = queueStore.entries.last {
        _ = queueStore.play(entryID: lastEntry.id)          // 普通队列：队首绕回队尾
        selectAndPlay(lastEntry.track)
    } else { seekToAbsolute(0) }
}
```

**边界行为**：第一首按 previous → 列表循环则跳队尾、否则回本曲开头（`seekToAbsolute(0)`）。超过 3 秒先回本曲开头而非上一首。定位一律基于 `QueueEntry.id` / logical index（R05），不按 TrackID。

### 3.2 next()（`AuralisAppModel.swift:4097`）

```swift
public func next() {
    if isShuffled { playRandomFromQueue(); return }
    if let logical = largeLogicalContext, let lIdx = largeLogicalCurrentIndex {
        if lIdx + 1 < logical.count {
            let target = lIdx + 1
            ensureLargeWindowContains(logicalIndex: target)
            if let next = queueStore.advanceForward() {
                shufflePlayedLogicalIDs.insert(target)
                selectAndPlay(next); refillLargeWindowIfNeeded(); return
            }
            let track = logical[target]
            rebuildLargeWindow(around: target)
            selectAndPlay(track, reconcileQueue: false); return
        } else if repeatMode == .all, logical.count > 1 {
            let first = logical[0]                          // 队尾 + 列表循环 → 绕回首首
            rebuildLargeWindow(around: 0)
            selectAndPlay(first, reconcileQueue: false); return
        }
        return
    }
    if let next = queueStore.advanceForward() {
        selectAndPlay(next)
    } else if repeatMode == .all, queueStore.count > 1, let firstEntry = queueStore.entries.first {
        _ = queueStore.play(entryID: firstEntry.id)         // 普通队列：队尾绕回队首
        selectAndPlay(firstEntry.track)
    }
}
```

**边界行为**：最后一首按 next → 列表循环则绕回队首、否则不动作（停在末尾，由 `handleTrackEnded` 决定 pause）。

`advanceForward()` / `advanceBackward()`（`PlaybackQueuePresentationStore.swift:344-357`）纯 index 推进，`guard entries.indices.contains(...)` 越界返回 nil（循环绕回由调用方处理）。

---

## 4. Repeat / Shuffle

### 4.1 枚举（`Domain/Protocols.swift:85`）

```swift
public enum RepeatMode: String, CaseIterable, Codable, Sendable {
    case off
    case all
    case one
}
public var next: RepeatMode {  // 切换顺序固定
    switch self {
    case .off: .all
    case .all: .one
    case .one: .off
    }
}
```

### 4.2 单曲循环（one）

- `handleTrackEnded()`（`:5086-5088`）：`case .one: selectAndPlay(currentTrack)`——自然播完重播当前。
- `seamlessNextTarget()`（`:5134`）：`guard !isShuffled, repeatMode != .one else { return nil }`——**单曲循环下不预载下一首**（无 gapless 准备）。
- `handlePreparedTrackStarted`（`:5206-5209`）：即便模式切换竞态导致旧预载项被引擎自动推进，仍 `selectAndPlay(currentTrack)` 回到单曲循环语义。

### 4.3 列表循环（all）

- next/previous 队尾↔队首绕回（§3）。
- `handleTrackEnded`（`:5089-5104`）：`all` + 有 next → `next()`；单曲队列 → 重播；否则 `firstTrack` 或 `pauseAtQueueEnd()`。

### 4.4 Shuffle

- `isShuffled` 开关；`playRandomFromQueue()`（`AuralisAppModel.swift:4176`）：
  - 候选池 = 队列中**尚未播放过**的非当前项；记录用 `QueueEntry.id`（`shufflePlayedEntryIDs`）或 logical index（`shufflePlayedLogicalIDs`），重复歌曲 A₁/A₂ 是两个独立 occurrence（R05）。
  - 大上下文时候选池基于 `largeLogicalContext`（`:1926-1939`），避免只在 256 窗口内随机。
  - 池空时：若 `repeatMode == .all` 则 `shufflePlayed*.removeAll()` 重置继续随机；否则 `return false`（随机+不循环：一轮播完即停，不隐式循环）（`:4183-4221`）。
- `shuffleRemainingInQueue()`（`:4144`）：仅打乱当前项之后的尾部（`items[tailStart...].shuffle()`），保持已播顺序。
- 任何队列编辑都会重置 shuffle 播放记录（`shufflePlayedLogicalIDs.removeAll()`，`:205` 等）。

---

## 5. 失败恢复

### 5.1 引擎层上报失败（`AVFoundationPlaybackEngine.swift`）

- **item failed**：`observeItemFailure`（`:892`）注册 `status == .failed` KVO 与 `AVPlayerItemFailedToPlayToEndTime` 通知 → `reportPlaybackFailure()`。
- **stalled**：`AVPlayerItemPlaybackStalled` 通知（`:914-929`）→ `.stalled` + `startStallTimeout()`。
- **同一 item 失败去重**：`failureReported`（`:51`、`:990`）防止 FailedToPlayToEndTime 与 status==.failed 双触发减半重试预算。
- **stalled 超时真实秒数 = 15 秒**（`startStallTimeout`，`:1001-1010`）：

```swift
private func startStallTimeout() {
    stallTimeoutTask?.cancel()
    stallTimeoutTask = Task { [weak self] in
        try? await Task.sleep(for: .seconds(15))
        guard let self else { return }
        guard !Task.isCancelled else { return }
        if self.playbackState == .playing || self.playbackState == .paused { return }
        self.reportPlaybackFailure()
    }
}
```

- `reportPlaybackFailure()`（`:987-997`）：置 `playbackState = .failed(.engineFailure("播放中途失败"))`，调用 `playbackFailureHandler?()`。恢复路径（playing/paused/resume/play/stopAll）均 `cancelStallTimeout()`。

### 5.2 上层恢复（重新解析流地址 + 重试预算）

`engine.setPlaybackFailureHandler { ... self?.handleStreamFailure() }`（`AuralisAppModel.swift:989-993`）。

`handleStreamFailure()`（`:5526-5593`）核心：

```swift
private func handleStreamFailure() {
    let track = currentTrack
    guard track.id.rawValue != "placeholder" else { return }
    let gid = queueIdentity(track)
    let attempts = streamRetryAttempts[gid, default: 0]
    guard attempts < Self.maxStreamRetryAttempts else {       // 重试预算上限
        streamRetryAttempts[gid] = 0
        lastStopReason = .streamExpired
        playbackError = .engineFailure(String(localized: "流地址失效，已重试仍无法播放", ...))
        playbackState = .failed(.engineFailure(...))
        if canGoNext { next() }                                // 用 canGoNext，避免 fail→repeat→fail 自旋
        return
    }
    streamRetryAttempts[gid] = attempts + 1
    playbackState = .buffering
    Task { @MainActor in
        let refreshed = await resolvePlayableTrack(track, forceRefresh: true)  // 重新解析流 URL
        ...
        guard let refreshed else {
            self.streamRetryAttempts[gid] = Self.maxStreamRetryAttempts        // 取不到新地址 → 按耗尽处理
            self.handleStreamFailure(); return
        }
        ... // playWithMusicHaptics + engine.play，失败递归 handleStreamFailure
    }
}
```

- **重试次数上限 = 2**：`private static let maxStreamRetryAttempts = 2`（`AuralisAppModel.swift:792`），按 `GlobalID` 隔离（`streamRetryAttempts: [GlobalID: Int]`，`:791`）。
- **是否重新 resolve stream URL：是**。`resolvePlayableTrack(_:forceRefresh:)`（`:3026-3054`）优先本地缓存（`cachedFileURL`），否则 `connector.refreshStreamURL(serverID:trackID:)`（`:3046`）刷新远端地址；跨服务器安全：非活动服务器曲目不刷新（`:3042`）。
- 取不到新地址或 play 抛错 → 递归 `handleStreamFailure`，最终耗尽进入 `failed` + `canGoNext` 自动下一首（不无限自旋）。
- 用户手动 `retryPlayback()`（`:2543`）同样 `resolvePlayableTrack(forceRefresh:true)` 后 `selectAndPlay`。

---

## 6. ReplayGain（纯算法，1:1 移植到 Kotlin）

### 6.1 数据模型

`ReplayGainMetadata`（`Domain/Models.swift:147`）字段：`trackGainDB? / albumGainDB? / trackPeak? / albumPeak? / baseGainDB? / fallbackGainDB?`。

`ReplayGainSettings`（`Domain/Protocols.swift:72-82`）：

```swift
public struct ReplayGainSettings: Codable, Hashable, Sendable {
    public var mode: ReplayGainMode           // .off / .track / .album
    public var preampDB: Double
    public var peakProtection: Bool
    public init(mode: ReplayGainMode = .off, preampDB: Double = 0, peakProtection: Bool = true) {
        self.mode = mode
        self.preampDB = min(max(preampDB.isFinite ? preampDB : 0, -12), 12)  // 前级范围 -12...+12 dB
        self.peakProtection = peakProtection
    }
}
```

> 前级 preamp 范围 **[-12, +12] dB**，默认 0；UI 步进 0.1 dB（`SettingsDetailPages.swift:108` 用 `%+.1f`）。peakProtection 默认 `true`。

### 6.2 纯计算逻辑（逐字引用，`PlaybackEngine/ReplayGain.swift:44-106`）

```swift
public enum ReplayGainCalculator {
    public static func adjustment(
        metadata: ReplayGainMetadata?,
        settings: ReplayGainSettings
    ) -> ReplayGainAdjustment {
        guard settings.mode != .off else { return .disabled }
        guard let metadata else {
            return .init(source: .missing, requestedGainDB: 0, appliedGainDB: 0, linearMultiplier: 1, peakLimited: false)
        }

        let selected: (Double?, Double?, ReplayGainAdjustment.Source)
        switch settings.mode {
        case .off:
            return .disabled
        case .track:
            selected = (finite(metadata.trackGainDB), validPeak(metadata.trackPeak), .track)
        case .album:
            selected = (finite(metadata.albumGainDB), validPeak(metadata.albumPeak), .album)
        }

        let directGain = selected.0
        let fallback = finite(metadata.fallbackGainDB)
        guard let contentGain = directGain ?? fallback else {
            return .init(source: .missing, requestedGainDB: 0, appliedGainDB: 0, linearMultiplier: 1, peakLimited: false)
        }

        let source: ReplayGainAdjustment.Source = directGain == nil ? .fallback : selected.2
        let baseGain = finite(metadata.baseGainDB) ?? 0
        let requestedDB = min(max(contentGain + baseGain + settings.preampDB, -60), 24)
        var multiplier = pow(10, requestedDB / 20)
        var peakLimited = false

        if settings.peakProtection, let peak = selected.1 {
            let maximum = 1 / peak
            if multiplier > maximum {
                multiplier = maximum
                peakLimited = true
            }
        }

        guard multiplier.isFinite, multiplier > 0 else {
            return .init(source: .missing, requestedGainDB: 0, appliedGainDB: 0, linearMultiplier: 1, peakLimited: false)
        }
        let appliedDB = 20 * log10(multiplier)
        return .init(
            source: source,
            requestedGainDB: requestedDB,
            appliedGainDB: appliedDB,
            linearMultiplier: Float(multiplier),
            peakLimited: peakLimited
        )
    }

    private static func finite(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return value
    }

    private static func validPeak(_ value: Double?) -> Double? {
        guard let value = finite(value), value > 0 else { return nil }
        return value
    }
}
```

### 6.3 移植要点（写单测用）

1. **mode 枚举**：`.off / .track / .album`（`.off` 直接返回 `disabled`，不计算）。
2. **先行钳位（requestedDB）**：`min(max(x, -60), 24)`——增益上下限 -60 dB ~ +24 dB。
3. **线性倍率**：`multiplier = 10^(requestedDB / 20)`；回写 `appliedGainDB = 20 * log10(multiplier)`。
4. **peak protection**：开启且所选 peak 有效（>0）时，`maximum = 1/peak`，若 `multiplier > maximum` 则钳到 maximum 并置 `peakLimited = true`。注意：`selected.1` 在 track 模式取 `trackPeak`、album 模式取 `albumPeak`。
5. **source 判定**：直接 gain 缺失（`directGain == nil`）则用 `fallbackGainDB`，source 标 `.fallback`；否则取 `.track`/`.album`。
6. **baseGain**：`finite(metadata.baseGainDB) ?? 0`，叠加在 contentGain 上再 + preampDB。
7. **adjustment 的最终输出**：`ReplayGainAdjustment`（`:4-40`）含 `source / requestedGainDB / appliedGainDB / linearMultiplier: Float / peakLimited`。
8. **输出应用（iOS 侧，供参考）**：`applyOutputVolume`（`AVFoundationPlaybackEngine.swift:882`）`avPlayer.volume = min(max(volume * linearMultiplier, 0), 1)`（AVPlayer.volume 限 0...1，正增益用剩余 user-volume 余量钳位，不直接做 DSP boost）。

---

## 7. 播放速度（Playback Speed）

- 取值：`playbackRate` 默认 `1.0`（`AVFoundationPlaybackEngine.swift:113`）；`setRate(_:)` 钳取 **0.5...2.0**（`:117`：`min(max(rate, 0.5), 2.0)`）。
- 保持策略：`playbackRate` 是引擎实例变量，**跨切歌/暂停/失败重试持久保存**。`play()`（`:435-437`）、`resume()`（`:541-543`）、`finishPreparedTransition`（`:852-854`，无缝推进后）均在新/复用 AVPlayer 创建或恢复后立即 `player.rate = playbackRate`，避免冷启动/换曲/暂停恢复后悄悄回到 1.0×。
- 仅当 `playbackState ∈ {playing, buffering, stalled}` 时 `setRate` 实时驱动 `avPlayer?.rate`（`:119-121`）。

## 8. 预载（prepareNext / preparedTrackStartedHandler）

- `prepareNext(track:)`（`AVFoundationPlaybackEngine.swift:455-508`）：把下一首 `AVPlayerItem` 插入 `AVQueuePlayer` 当前项之后（`player.insert(item, after: nil)`），系统可后台缓冲实现 gapless。约束：若 `boundaryCoordinator.state == .waitingForPreparedAdvance`（边界未决）则拒绝替换（`:468`）；`track.streamURL == nil` 或无 currentItem 时直接返回。
- **preparedTrackStartedHandler**（`AVFoundationPlaybackEngine.swift:137`、`:856`、`:823-857`）：当 `AVQueuePlayer` 已无缝推进到 prepared item（无需再次 `play(track:)`）时，`finishPreparedTransition` 调用 `preparedTrackStartedHandler?(track)`。AppModel 的 `handlePreparedTrackStarted`（`:5191`）**只更新模型游标/历史/Now Playing，绝不重建播放器**，避免破坏无缝衔接；并把 `playbackRate` 重应用。
- 边界协调：`PlayerItemBoundaryCoordinator`（`:72`）解决「DidPlayToEnd 与 currentItem 变化顺序不确定」导致的双重/漏推进（exactly-once）；`boundaryFallbackTimeout = .seconds(3)`（`:75`）兜底（prepared 未在 3s 内成为 current 则只触发一次 `trackEndedHandler`）。
- 单曲循环（`repeatMode == .one`）下不预载下一首（`seamlessNextTarget` 直接 `return nil`）。

---

## 9. Protocols.swift —— 播放相关协议方法签名

### 9.1 `PlaybackControlling`（`Domain/Protocols.swift:11-56`，全部 `async`/`Sendable`）

```swift
public protocol PlaybackControlling: Sendable {
    func state() async -> PlaybackState
    func play(track: Track) async throws
    func pause() async
    func resume() async throws
    func stop() async
    func setVolume(_ volume: Float) async                       // 默认空实现
    func setRate(_ rate: Float) async                           // 默认空实现
    func seek(to position: TimeInterval) async                  // 默认空实现
    func currentPosition() async -> TimeInterval?              // 默认 nil
    func currentDuration() async -> TimeInterval?              // 默认 nil
    func setTrackEndedHandler(_ handler: (@Sendable () -> Void)?) async
    func setPlaybackFailureHandler(_ handler: (@Sendable () -> Void)?) async
    func prepareNext(track: Track?) async                       // 默认空实现
    func setPreparedTrackStartedHandler(_ handler: (@Sendable (Track) -> Void)?) async
    func setPlaybackTimingHandler(_ handler: (@Sendable (PlaybackTimingUpdate) -> Void)?) async
    func configureReplayGain(_ settings: ReplayGainSettings) async
}
```

> 协议 `PlaybackControlling` 方法全部默认空实现（`:44-56`），保证兼容。Android 侧 Media3 播放器需实现全部有默认实现的成员（Kotlin 无协议默认实现，需自行提供 no-op/真实实现）。

### 9.2 其它播放相关协议/类型（同文件）

- `MusicLibraryRepository`（`:3-9`）：`artists/albums/tracks/track/search`（与播放间接相关，供队列源）。
- `ReplayGainMode`（`:58-70`）：`.off / .track / .album`，`title` 本地化。
- `ReplayGainSettings`（见 §6.1）。
- `RepeatMode`（见 §4.1）。
- `QueuePersisting`（`:134-137`）：`save(trackIDs:currentIndex:position:)` / `restore() -> RestoredQueue?`——播放会话持久化（队列只持久化逻辑 trackIDs，非窗口）。
- `MetadataAgent`（`:115-119`）：metadata 写入（与播放无关，列出备查）。

### 9.3 关联领域类型（供 Kotlin 建模）

- `PlaybackTimingUpdate`（`Domain/Models.swift`，供 `setPlaybackTimingHandler`）：携带 `state: PlaybackTimingState`、`position`、`rate`、`isStateTransition`。
- `PlaybackTimingState`：`buffering / playing / paused / stalled`（`:1:1` 对应非 idle/preparing/failed 的 timing 事件）。
- `QueueEntry`（`PlaybackQueuePresentationStore.swift`）：`id: UUID`，`track: Track`——身份与歌曲解耦（R05）。
- `QueueSnapshot` / `PlaybackQueueStore`（actor，`PlaybackQueue.swift`）：旧版同步队列，已被 `PlaybackQueuePresentationStore` 取代，迁移时以 `PlaybackQueuePresentationStore` 的 O(1) API 为准。

---

## 10. Android（Media3 / ExoPlayer）实现清单

1. **状态机**：实现 7 态（无 `ended`）；自然播完经 `Player.Listener.onPlaybackStateChanged(STATE_ENDED)` → 自定义 `trackEndedHandler`。stalled 用 `Player.STATE_BUFFERING` + 自定义 15s 超时 → 失败。失败态免疫（见 §1.2）。
2. **队列**：实现 logical list + 256 窗口物化；阈值 500 / initial 256 / refill ≤48 / batch 192。窗口随 index 滑动逻辑（§2.3 逐字）。重复歌曲用独立 UUID entry。
3. **previous/next**：3 秒阈值回本曲开头；边界基于 entry UUID / logical index；列表循环绕回。
4. **repeat/shuffle**：固定 `off→all→one` 切换；shuffle 用「已播集合」按 entry/occurrence，非 TrackID；单播完停。
5. **失败恢复**：重试上限 2（按曲目 ID 隔离），重新 `refreshStreamURL`；耗尽后 `canGoNext` 自动 next 不自旋。
6. **ReplayGain**：§6.2 算法 1:1 移植 + 单测（建议覆盖：off/缺失元数据/fallback/峰值钳位/±60~±24 钳位/NaN 输入）。
7. **速度**：0.5–2.0 钳位，跨切歌/暂停持久；gapless 推进后重应用。
8. **预载**：`ExoPlayer` 顺序 `addMediaItem` 预载下一首；advance 时经 `preparedTrackStartedHandler` 仅更新模型游标。
9. **协议**：`PlaybackControlling` 全部方法在 Android 接口中均须提供真实或 no-op 实现（无默认实现语法）。
