# Auralis 完整规范化整改报告

审计基准：当前本地工作区。验证日期：2026-08-11。验证工具链：Xcode Beta
`27A5209h`。本报告只记录代码、自动测试和命令行 Release 构建能够证明的结果；真实
NAS、真机音频、动画手感及 Instruments 数据统一列为 `MANUAL-VERIFY`。

## 1. 总体结果

阶段 A～M 已连续完成。Auralis 仍保持“私人 NAS / OpenSubsonic 原生音乐客户端”的
定位，没有引入多 Agent、社交、排行榜、云端画像或新的第三方依赖。主要结果如下：

- Agent 已形成单 `AgentRuntime`、结构化任务状态、Policy/Scope、Budget、Completion、
  Evidence 和注册表工具体系；
- NAS 目录以 `catalog.sqlite` 为权威，支持 revision/fingerprint 探测、持久化 staging、
  中断续传、原子提交和离线恢复；
- 长期实体、离线下载、歌词、播放历史、Agent 偏好和外部音乐身份使用服务器作用域的
  `GlobalID`；
- 播放器增加下一项预备、generation 隔离、best-effort seamless 和 ReplayGain；
- 首页大曲库投影、搜索、封面和网络探测的主线程/生命周期热点已收敛；
- iPhone/iPad/macOS 导航、Dock 和 Accessibility 完成代码层规范化；
- 歌曲鉴赏严格区分事实、推断、私人数据与可核验社区数据；
- MusicBrainz、ListenBrainz、CritiqueBrainz 已按单曲、按需、可缓存地接入；
- SwiftPM 全量串行测试实际执行 419 项并通过；iOS 与 macOS Release 构建通过。

## 2. Agent 架构

最终调用链为 `UI / Siri / App Intent → AgentCoordinator → AgentRuntime →
AgentRunner → AgentToolRegistry → LocalCatalog / AgentBridge / SystemService`。

- `AgentRuntime` 是 actor，控制任务生命周期、模型轮次、工具执行、预算、取消、重试、
  状态归并、完成判断和诊断；不持有 SwiftUI View。
- `AgentCoordinator` 是 `@MainActor` UI Adapter，只负责会话、消息、运行态、确认态和
  Runtime event 到 UI 的映射。
- `TaskIntent` 在任务创建时确定；明确入口传显式 Intent，自由文本使用保守分类。
- `TaskPolicy` 为该 Intent 产生允许工具组、风险、读写性质和完成条件。
- `GrantedScope` 在工具存在之外再做一次任务级授权，越权调用会在执行前被拒绝。
- `AgentTaskState` 保存 goal、事实、证据、实体、动作、预算、错误和终态，是任务权威。
- `AgentTaskBudget` 同时限制墙钟时间、模型轮次、token、无进展和重复模式，而不是用一
  个很小的工具次数硬截断；有效副作用会被识别为进展。
- `AgentCompletionPredicate` 根据结构化事实判断完成；模型的自然语言宣称不能替代真实
  工具证据。
- `AgentToolRegistry.execute` 是唯一公开执行路径；descriptor 自描述 schema、权限、
  side effect、Evidence、缓存和结果大小。
- `Evidence` 携带来源与时间，只有非模型推断证据才能满足需要真实事实的任务。
- `AgentContextBuilder` 仅提供任务所需目录切片；不把整库、海报、流地址、路径或凭据
  放入 Prompt。

完整设计见 `Docs/AgentArchitecture.md`。

## 3. Agent 已删除的旧架构债务

- Runner 中索引 V2 专属循环/超时/摘要解析已移除，索引成为普通
  `RecommendationIndexToolService`；是否完成只看 `pending == 0` 结构化事实。
- 工具执行不再由 Runner、Toolkit 和 Registry 分别维护路由；Toolkit 旧入口只转发到
  Registry，系统工具也经统一 executor。
- 通用任务状态从只服务歌曲候选的 WorkingSet 中拆出；WorkingSet 不再硬编码 20 首。
- 工具 schema、权限、side effect 和结果限制集中到 descriptor，删除重复 metadata。
- Runtime 不再从中文摘要反解析事实，也不再将模型推断写成本地/服务器 Evidence。
- 重复副作用由签名和完成动作阻止；成功的不同副作用不会再被错误判为“无进展”。

## 4. Agent 自动测试

以下测试均在 2026-08-11 使用 Xcode Beta 工具链实际执行，并包含在 419 项全量串行
测试中：

| 测试 | 实际执行 | 结果 |
| --- | --- | --- |
| Intent 分类、显式 UI Intent、Policy/GrantedScope | 是 | 通过 |
| 越权工具拒绝、风险与只读约束 | 是 | 通过 |
| Budget、超时、取消、无进展与重复停止 | 是 | 通过 |
| 12+ 模型轮次及 305 次合法工具调用 | 是 | 通过 |
| OpenAI Responses / Chat Completions 多轮 tool-call 配对 | 是 | 通过 |
| 成功副作用去重、工具失败后继续与缺失系统能力 | 是 | 通过 |
| Task reducer、Evidence 与 Completion Predicate | 是 | 通过 |
| 上下文合法 tool-call 配对及隐私脱敏 | 是 | 通过 |
| 索引 V2 只有 pending=0 才完成 | 是 | 通过 |
| 歌曲鉴赏四段格式和无社区证据回退 | 是 | 通过 |

真实模型端点仍需按第 15 节执行真机测试，不能由 fixture 替代。

## 5. NAS 同步

- 优先使用服务器真实 revision/scan id；无法提供时对目录稳定字段生成 fingerprint；再无
  能力时使用 song count 作为较弱 fallback。
- `catalog.sqlite` 是目录事实源。探测值未变化且仍在冷却期时跳过全量拉取；恢复连接只
  读本地目录，不把启动变成强制联网。
- `sync_sessions`、checkpoints 和 artists/albums/tracks staging 持久化；进程重启可恢复
  同一 session。完成后事务性替换可见数据，失败或取消不会先清空旧目录。
- 旧 file-backed snapshot 只承担一次迁移兼容；账号/凭据仍走既有安全存储。
- NAS 离线时保留上次成功目录、歌单和已下载内容；网络恢复后再做 revision 探测。

## 6. GlobalID

服务器复用相同 remote ID 时不会再互相覆盖。当前迁移/约束覆盖：目录实体、歌单及曲目
关系、播放历史、收藏与评分、Agent 偏好、歌词磁盘/负缓存、离线下载索引与恢复映射、
推荐索引和外部音乐身份。旧缓存只在能够确定 last active server 时执行一次迁移；不能
安全归属的数据不会被猜测式合并。Tool 参数还会验证 GlobalID 属于当前服务器。

## 7. 性能

仅确认以下代码级变化，不宣称 FPS、内存或百分比提升：

- 2,000 首以上首页投影在可取消 utility task 中计算，并以 generation 丢弃过期结果；
- 搜索一次 body 只生成一份结果，继续保留 150ms 防抖；
- Agent 播放统计先建 TrackID 查找表，移除循环内全库 `first(where:)`；
- 封面由 ImageIO 按目标像素后台下采样；缩略图/大图使用有界缓存，相同请求合并；
- 本地网络探测超时会取消 `NWConnection`，不遗留 handler/计时器链；
- 首页、资料库、服务器和下载状态拆入领域 Store，降低巨型 Model 广播范围。

数值基线与 Instruments 步骤见 `Docs/PerformanceBaseline.md`。

## 8. 播放稳定性

- 播放回调使用 generation 隔离；旧 item 的 end/failure/stall 不能修改新播放状态。
- interruption、route change 和 remote command observer 具有单一所有权，避免重复注册。
- 队列编辑、随机、循环和睡眠计时会使已准备的下一项失效并重新计算。
- 预备切换只更新一次 Model/Now Playing，不再次调用 `play(track:)`。
- 暂停恢复和下载任务恢复保存服务器作用域；取消下载的 tombstone 阻止异步
  `getAllTasks` 把已取消任务重新绑定。
- 流地址过期、手动上一/下一首和边界时队列变化仍走受控 fallback。

## 9. Gapless

实现是 **best-effort seamless**：同一个 `AVQueuePlayer` 预建下一 `AVPlayerItem` 并允许
缓冲，边界不主动 teardown/replay，也不做 crossfade。最适合本地兼容文件和未转码原始
流；HTTP、服务器转码、codec/container priming 与 AVFoundation 仍可能产生听得见的
缝隙，因此不宣称 sample-perfect gapless。真机矩阵见第 15 节。

## 10. ReplayGain

数据来自 OpenSubsonic `Child.replayGain`：track/album gain、track/album peak、base 与
fallback gain。模式为 Off（默认）、Track、Album；计算使用 `10^(dB/20)`，preamp 限制
在 -12...+12 dB，Peak Protection 将倍率封顶到 `1/peak`。缺失或非法元数据保持 unity，
不偷偷替换为通用音量归一化。`AVPlayer.volume` 无法超过 full scale，所以只准确施加衰减
和可用 headroom 内的正增益。听测见第 15 节。

## 11. Apple 规范化

- iPhone 浏览详情使用 `NavigationStack/navigationDestination`，iPad 保留
  `NavigationSplitView`，macOS 保留独立侧边栏窗口语义。
- 当前最低 iOS 26 虽支持系统底栏附件，但系统 API 无法表达现有 Dock/AI 输入/首页入口
  的连续重组，因此只保留一套自定义 Dock，没有双实现。
- Dock 手势具有阈值、固定时长和 Reduce Motion 路径；Reduce Transparency 改用不透明
  系统背景并移除 glass-on-glass。
- 关键点击区域至少 44pt，裸 `onTapGesture` 列表项改为语义化 Button，并补充
  VoiceOver label/value/action。
- Glass 只用于控制层，不用于正文列表和内容卡片。

代码审计见 `Docs/ApplePlatformAudit.md`。设计依据为 Apple 的 SwiftUI Glass、辅助功能、
Motion 与底栏 API；真机手感仍需人工验证。

## 12. AuralisAppModel

`AuralisAppModel` 现在主要负责 App 级导航与跨领域接线，并为尚未迁移的调用点提供不
存储第二份状态的兼容代理。已拆出：

- `PlaybackStore`：播放状态唯一来源；
- `ArtworkStore`：封面内存缓存和管线；
- `HomeStore`：首页布局、投影、generation/cancellation；
- `LibraryStore`：目录与浏览投影；
- `ServerStore`：连接和能力状态；
- `DownloadStore`：GlobalID 下载状态与恢复映射。

后续新页面应直接观察最小 Store，不再向 AppModel 增加页面级 `@Published`。

## 13. 歌曲鉴赏

输出强制分成四个证据域：

1. `【已核验事实】`：本地目录、播放状态、歌词可用性和已核验外部实体；
2. `【模型分析】`：明确标识的音乐结构/风格推断；
3. `【我的私人数据】`：个人评分、收藏、播放历史，仅本地使用；
4. `【大众评价】`：只列带 provider/entity/date 的外部证据。

Completion Predicate 会验证元数据、歌词和大众评价的 available/unavailable 状态。没有
可核验来源时必须输出固定文本“暂无可核验的大众评价数据。”，不能拿模型常识或私人
数据冒充社会评价。

## 14. 外部音乐数据

- MusicBrainz：识别 recording/release/release-group/artist，读取 recording rating/votes；
- CritiqueBrainz：读取 release-group rating/count/review count；
- ListenBrainz：读取端点实际提供的 listen/listener count；
- 三个来源分别存储和显示，不制造综合评分或排行榜。

匹配顺序为既有 MBID、ISRC、标题+艺人+时长、专辑/版本、保守模糊匹配。置信度
`>=0.90` 才自动绑定，`0.65..<0.90` 只存候选。成功/无数据缓存 14 天；请求可取消、
15 秒超时、有错误分类与 User-Agent，MusicBrainz 平均间隔至少 1.05 秒。启动不扫描
整库，只在歌曲信息或歌曲鉴赏时查询当前歌曲。完整约束见 `Docs/ExternalMusicData.md`。

## 15. MANUAL-VERIFY

### P0

- 真机 Release 连续播放、前后台、锁屏、强退恢复、Repeat/Shuffle/睡眠计时；
- LAN/WAN 切换、NAS 中断/恢复、旧流地址、本地离线播放和取消后台下载；
- 电话、Siri、耳机拔出、蓝牙和 AirPlay 路由切换。

### P1

- 本地 FLAC、LAN 原始流、WAN 转码的连续专辑 Gapless 听测及 ReplayGain 听测；
- MusicBrainz/ListenBrainz/CritiqueBrainz 真实端点、缓存、断网和隐私网络检查；
- iPhone/iPad/macOS 的 Navigation、Dock、键盘、VoiceOver、动态字体、Reduce Motion、
  Reduce Transparency 与 Increase Contrast。

### P2

- 8,000～10,000 首曲库的 SwiftUI、Time Profiler、Core Animation、Allocations/Leaks、
  Network 冷/热 baseline 和两小时稳定性；
- OpenAI 原生 Responses/兼容 Chat Completions 的真实多轮、取消、重启和完整索引任务。

每项前置条件、Xcode Beta 操作、预期结果和失败证据均已写入
`Docs/ManualValidation.md`。

## 16. MANUAL-DECISION

无。本轮没有发现必须由用户选择才能安全落地的不可逆数据/协议变化。

## 17. 尚存问题

### P0

无已知代码级 P0。

### P1

- Gapless、后台生命周期、真实 NAS 网络切换和音频路由尚未完成真机矩阵，不能仅凭单元
  测试保证实际硬件/服务器组合。
- 外部公共数据的实时可用性和真实条目覆盖率需要真机联网验证。

### P2

- 尚无 Instruments 数值 baseline；性能修改只完成代码和自动构建层验证。
- `AuralisAppModel` 仍有兼容代理和变化转发，旧 View 尚未全部直接观察领域 Store。
- iOS 为支持用户自填的 HTTP 内外网音乐服务器仍保留 ATS arbitrary loads；凭据和请求
  已受现有边界保护，但未来可在产品明确限定域名/HTTPS 后进一步收紧。
- 三处内存/应用组合入口仍以 `try! LocalCatalogStore(:memory:)` 表达“内建数据库必须可
  创建”的启动不变量。未用于解析外部数据，但后续可将 composition 改为显式 throwing
  bootstrap 后移除。

### P3

- 为迁移旧调用点保留的 Toolkit/AppModel 兼容转发可以在所有调用者切换后删除。
- ListenBrainz/CritiqueBrainz 的公共数据覆盖不均，这是外部数据源限制，不应通过模型
  猜测补齐。

## 18. 下一步

1. 严格按 `Docs/ManualValidation.md` 先完成 P0 真机验收，再进入长期使用；
2. 保存首轮 Instruments trace 作为可复现 baseline，不以肉眼评价性能；
3. 逐页注入 Home/Library/Server/Download Store，最终删除 AppModel 兼容转发；
4. 在真实 NAS 的原始流/转码矩阵上记录 Gapless 与 ReplayGain 限制；
5. 若未来强制服务器 HTTPS，再评估移除 ATS arbitrary loads；
6. 将 composition 初始化改为显式可失败 bootstrap，清理最后三处启动不变量 `try!`。

## 阶段 M：40 项最终审计表

| # | 项目 | 状态 | 结论 / 证据 |
| ---: | --- | --- | --- |
| 1 | Swift 6 strict concurrency | 已验证 | SwiftPM 及 iOS/macOS Release 编译通过。 |
| 2 | actor isolation | 已验证 | Runtime、Catalog/图片磁盘管线等可变并发域为 actor/受隔离服务。 |
| 3 | MainActor | 已验证 | Coordinator/UI adapter 在 MainActor；大目录投影和网络不阻塞其执行。 |
| 4 | Sendable | 已验证/残留可控 | 跨任务值为 Sendable；少数 `@unchecked` 包装器由锁或不可变平台图像载荷支撑。 |
| 5 | Task cancellation | 已验证 | Agent、首页快照、外部 API、封面与网络探测均传播/处理取消。 |
| 6 | retain cycles | 已验证/需真机 | observer/connection/task 所有权已复核；Leaks 仍需真机。 |
| 7 | timers | 已验证 | 网络 timeout 与播放计时具有取消/替换路径。 |
| 8 | observers | 已验证 | memory pressure token 自清理；播放 observer 单一注册并替换。 |
| 9 | URLSession | 已验证 | 外部 API、下载、服务器请求均为异步路径；下载恢复有 task metadata。 |
| 10 | network timeout | 已验证 | 外部 API 15 秒；本地探测超时会终止 connection；错误分类保留。 |
| 11 | database transactions | 已验证 | 同步 staging 原子 commit；外部数据与迁移使用事务/幂等 upsert。 |
| 12 | migrations | 已验证 | schema 为 additive/idempotent；旧 snapshot/缓存迁移不先破坏数据。 |
| 13 | GlobalID | 已验证 | 目录、播放历史、偏好、歌词、下载、索引和外部身份均服务器作用域。 |
| 14 | cache bounds | 已验证 | 封面双缓存、负缓存、Agent/tool 结果和波纹状态均有限制。 |
| 15 | image decode | 已验证 | ImageIO 后台按目标像素 downsample；View 不解码原始大图。 |
| 16 | Agent privacy | 已验证 | 按任务目录切片；不发送整库、流地址、路径、海报或默认歌词/历史。 |
| 17 | credentials | 已验证 | 凭据沿 Keychain/安全抽象；不进入 Prompt、Task、Session 或导出。 |
| 18 | logs | 已验证 | 敏感参数脱敏；临时 debug print 已清理；诊断仅 DEBUG。 |
| 19 | ATS | 残留 P2 | iOS 为任意用户 HTTP NAS 保留 arbitrary loads；见第 17 节。 |
| 20 | Local Network | 已验证/真机 | plist/探测代码存在；系统授权和 Beta 行为需真机。 |
| 21 | entitlements | 已验证 | iOS/扩展 App Group 与 Keychain、macOS sandbox/network 边界已复核。 |
| 22 | Background Audio | 编译通过/真机 | capability 与播放接线存在；生命周期列入 P0。 |
| 23 | Live Activity | 编译通过/真机 | extension 嵌入 iOS app；实际锁屏更新列入 P0。 |
| 24 | Siri | 编译通过/真机 | 入口连接 Coordinator/系统服务；真实语音交互需真机。 |
| 25 | App Intents | 已验证/真机 | Release metadata extraction 通过；运行授权/短语需真机。 |
| 26 | Accessibility | 代码已验证/真机 | 44pt、语义 Button、labels 和无障碍降级已补；体验列入 P1。 |
| 27 | download recovery | 已验证 | GlobalID 快照恢复；取消 tombstone 修复 getAllTasks 竞态并有测试。 |
| 28 | playback restore | 已验证/真机 | 暂停态、队列和服务器作用域恢复有自动覆盖；系统生命周期需真机。 |
| 29 | Gapless | 已验证/真机 | 预备 AVPlayerItem 的 best-effort seamless；听感列入 P1。 |
| 30 | ReplayGain | 已验证/真机 | Track/Album/fallback/preamp/peak 计算与解码有测试；听感列入 P1。 |
| 31 | Agent Runtime | 已验证 | 独立 actor、结构化 state/policy/budget/completion 已落地。 |
| 32 | Tool scopes | 已验证 | Registry 前按 Intent/Scope/Risk 授权，越权有测试。 |
| 33 | Agent loops | 已验证/真机 | 多轮、305 工具、无进展、重复和超时有测试；真实模型列入 P2。 |
| 34 | Evidence | 已验证 | 来源/时间结构化，模型推断不能满足工具事实完成条件。 |
| 35 | external APIs | 已验证/真机 | 按需、缓存、限速、timeout、取消和错误分类有 fixture；实时端点列入 P1。 |
| 36 | external music identity | 已验证 | MBID/ISRC/版本置信匹配、候选和 GlobalID 持久化有测试。 |
| 37 | error fallback | 已验证 | 网络/限流/认证/服务/解码分类；无数据不伪造，播放不被外部数据阻断。 |
| 38 | dead code | 已验证 | 临时 debug、重复 Runner 分支和本轮替代路径已清理。 |
| 39 | duplicate abstractions | 已验证/残留 P3 | Tool 执行单路径；AppModel/Toolkit 仅留不保存双状态的兼容转发。 |
| 40 | stale Recommendation Index | 已验证 | V2 保留为有效工具服务，无 Runtime 特殊分支，以 pending 事实完成。 |

## 最终自动验证记录

- `swift test --package-path Packages/AuralisCore --no-parallel`：419 项通过；
- `xcodebuild ... -scheme Auralis -configuration Release -destination generic/platform=iOS
  CODE_SIGNING_ALLOWED=NO build`：`BUILD SUCCEEDED`；
- `xcodebuild ... -scheme AuralisMac -configuration Release -destination platform=macOS
  CODE_SIGNING_ALLOWED=NO build`：`BUILD SUCCEEDED`（arm64 + x86_64）；
- `git diff --check`：作为最终交付检查执行，结果见本轮交付说明。
