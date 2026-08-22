# One Review 审查与修复记录（2026-08-22）

## 状态

- 分支：`one-review`
- 审查基线：`d36dbb23bb65d8dd6b2937a2e72c421bf054dfdb`
- 范围：Auralis iOS / iPadOS / macOS、AuralisCore 全部 Swift 源码与测试、CI、Agent 工具与权限、已有产品文档。
- 依据：先读初步审查 `/Users/zhengyunkai/.codex/attachments/236b100b-6bd1-4972-b6c7-b012237fede3/pasted-text-2.txt`，再读审查原则 `/Users/zhengyunkai/.codex/attachments/236b100b-6bd1-4972-b6c7-b012237fede3/pasted-text-1.txt`，随后逐文件检查实际实现与测试。
- 证据分类：源码/静态分析、回归测试、SwiftPM 测试、Debug/Release 构建、模拟器运行日志与截图分别记录，不把其中任何一种当成其他证据的替代。

## 修复清单

| ID | 优先级 / 置信度 | 触发路径与影响 | 精确修改 | 回归验证 |
| --- | --- | --- | --- | --- |
| QUEUE-001 | P1 / 高 | `PlaybackQueuePresentationStore.move` 对重复歌曲按 GlobalID `removeAll`，移动 `[A,B,A,C]` 时会错删 occurrence，导致顺序与持久化漂移。 | `Packages/AuralisCore/Sources/AppShell/PlaybackQueuePresentationStore.swift`：按 entry offset 倒序移除 `entries` 与 `persistenceTrackIDs`；`prepare` 增加 `selectedLocalIndex`。 | `PlaybackQueuePresentationStoreTests.movePreservesDuplicateOccurrences`；队列测试 17 项通过。 |
| QUEUE-002 | P1 / 高 | >500 首队列只物化可见窗口，窗口编辑会丢失未物化尾部；重启后只恢复窗口。 | `Packages/AuralisCore/Sources/AppShell/AuralisAppModel.swift`：`largeLogicalContext` 成为持久化与编辑权威，窗口只负责播放热路径；追加、下一首、shuffle、清空、移动、删除、保存歌单统一在逻辑队列上变更；快照保存完整 ID 与逻辑下标。修复异步预构造窗口的 `preparedWindowStart` 对齐问题。 | Agent/ AppShell 全套测试；Debug/Release 构建通过。大队列真实 10,000 首恢复仍需真机长时播放矩阵。 |
| SEARCH-001 | P2 / 高 | 在线搜索请求返回顺序与输入顺序不同，旧结果可能显示在新查询下。 | `AuralisAppModel.searchOnServer/clearServerSearch` 增加取消、generation、server/query 校验；`SearchView` 绑定结果查询词并在新查询开始时清空。 | SwiftPM 全套通过；需联网端点的真实搜索矩阵列入手工验收。 |
| AGENT-001 | P1 / 高 | 基线中 playlist/memory/skill 删除工具经 Coordinator 的 `confirm: { _ in true }` 直接到执行桥，存在不可逆误删。 | `AgentToolRegistry` 仅为 `playlist_delete`、`memory_delete`、`memory_clear`、`skill_delete` 标记 `requiresConfirmation`；`AgentRunner` 在副作用前等待一次任务级 UI continuation，拒绝跳过桥并抑制同签名重复询问；`AgentCoordinator` / `AssistantView` 提供批准与拒绝状态。普通播放、队列清空/替换、下载、服务器切换/本地删除、标注仍直接执行。 | `AgentPermissiveRuntimeTests` 41 项通过，覆盖批准一次、拒绝不执行、重复调用不重复弹窗；`CoordinatorRound3Tests` 通过。 |
| MEDIA-001 | P2 / 高 | 播放模式切换会把媒体控制中心上一首/下一首重新置灰；远端队列边界状态不随逻辑队列更新。 | `RemoteCommandCoordinator.syncState` 的 previous/next 改为可选增量更新；`SystemMediaIntegrationController.queueCapabilitiesChanged` 与 `AuralisAppModel.syncRemoteCommandCapabilities` 在队列、当前曲目、窗口重建、Now Playing 更新时同步。 | SwiftPM / iOS 与 macOS Release 构建通过；锁屏/控制中心真机矩阵仍需手工确认。 |
| DATA-001 | P2 / 高 | 小目录的派生艺术家/专辑索引异步发布，UI 立即读取时可能看到旧索引。 | `AppDomainStores.scheduleDerivedIndexRebuild` 对 <=1,000 曲目/专辑同步安装索引，较大目录继续使用 revision-gated detached rebuild。 | 修复前失败的 `MacArtistsRegressionTests` 与全 AppShell 263 项通过。 |
| CI-001 | P2 / 高 | CI 只有 Debug 与 generic iOS，无法发现 Release 优化/实际 Simulator 链路问题。 | `.github/workflows/ci.yml` 增加 macOS Release、generic iOS Release、可用 iPhone Simulator Debug 构建（无 runtime 时明确 warning 跳过）。 | 本地 macOS/iOS Release 与 iOS Simulator Debug 均通过。 |
| UX-001 | P2 / 中高 | 文档声称 iPad 三栏/`NavigationSplitView`，实际 root 是 iPhone/iPad 共用 `IOSMusicShell` + `NavigationStack`；误导后续维护与验收。 | 更新 `README.md`、`Docs/ApplePlatformAudit.md`、`Docs/ManualValidation.md`，明确统一 Shell、可读宽度、浮动 Dock 与 Stage Manager/分屏手工矩阵。未为了文档而引入第二套 iPad 架构。 | iPhone iOS 27 Simulator 启动与截图；当前机器没有可用 iPadOS 27 runtime，iPad 真机/分屏仍是剩余手工项。 |
| AI-001 | P2 / 高 | 兼容端点拒绝 tools/schema 时，旧回退请求把大模型输出强制 `min(..., 16K)`，会悄悄缩短用户/provider 配置。 | `AgentRunner` schema fallback 保留 `reservedOutput`；`AIProvider`、`ContextManager`、`AgentCoordinator` 注释改为 Provider/ModelCapabilities 驱动。现有设置档位支持 1M context / 128K output，Agent 不再添加固定 token 上限。 | SwiftPM 全套通过；需真实 400/422 中转端点验证请求体。 |

## Agent 能力边界

本轮采用用户明确的窄授权边界：只有达到“删除歌单、清空/删除记忆文件、删除技能文件”同等级不可逆程度的操作才需要批准。`permission` / `risk` / `scope` 继续作为描述和诊断元数据，不作为普通工具门禁。当前注册表已有搜索、目录索引、播放/队列、歌单、服务器、下载、设备网络/音频/存储、诊断、公开音乐证据、推荐、记忆与技能 CRUD 等 100+ 工具；没有为了凑数新增重复工具，也没有限制模型可用工具、上下文或 token。技能由 `skill_create`、`skill_list`、`skill_read`、`skill_delete` 管理，删除技能才触发批准。

## 安全扫描

已完成 Codex Security Standard 扫描：

- scanId：`05b58288-5953-436f-8ec9-587b8a743e95`
- 基线：`d36dbb23bb65d8dd6b2937a2e72c421bf054dfdb`
- 结果：1 个中危、高置信基线发现（`authorization.agent-irreversible-operation`），已由 AGENT-001 修复并由分支回归测试覆盖。
- 报告目录：`/private/var/folders/ry/bcnb7yhj78q160rpgq1tq3lr0000gn/T/codex-security-scans-bAyUwg/Auralis/d36dbb23bb65d8dd6b2937a2e72c421bf054dfdb_20260822T114200Z_xea_7luw/`
- 外部 TAC 建议因未登录未生成；这是工具服务状态，不影响本地静态扫描与分支回归验证。

## 当前运行证据

- iOS 27 Simulator：`测试`（`348744D2-86DF-41C6-867B-E7E1028CCBD0`），安装并启动 `com.auralis.player.ios` 成功，日志显示进程持续运行；截图为设置 → 数据与备份页面：[ios-home.png](OneReviewScreenshots/ios-home.png)。
- macOS Release App：启动成功，主页随机音乐/最近播放/最近添加与底部播放条可见；窗口截图：[macos-home-window.png](OneReviewScreenshots/macos-home-window.png)。首次运行网络权限弹窗另存为：[macos-home.png](OneReviewScreenshots/macos-home.png)。
- 模拟器文件验证：用户提供的 `Auralis设置备份-20260822-205626.auralisbackup` 已复制到 `测试` 模拟器 `Media/Downloads`，并与下载目录源文件完成 `cmp` 字节校验（源文件与设备侧均为 1,100 字节）；Files 进程可启动，当前系统画面截图：[files-downloads.png](OneReviewScreenshots/files-downloads.png)。
- 本轮按 Product Design 审计要求对截图做了实际视觉检查；截图证明布局和首屏可见状态，不替代 VoiceOver、Reduce Motion、真实音频、网络和真机锁屏验收。

## 验证命令与结果

```text
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path Packages/AuralisCore                         PASS
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -scheme AuralisMac -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build       PASS
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -scheme Auralis -configuration Debug -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build           PASS
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -scheme AuralisMac -configuration Release -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build     PASS
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -scheme Auralis -configuration Release -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build       PASS
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -scheme Auralis -configuration Debug -destination 'platform=iOS Simulator,id=348744D2-86DF-41C6-867B-E7E1028CCBD0' CODE_SIGNING_ALLOWED=NO build PASS
git diff --check                                                                                                                                                                  PASS
```

SwiftPM 结果：AppShell 263/263、Agent 248/248、Network Provider 86/86；合计 597 项通过。现存输出只有 Swift 6 的既有 warning（无需 `await` / 不必要 `try`），未发现新的编译错误。

## 续接点与剩余风险

1. 在有 iPadOS runtime 或真机后执行 RC-3：portrait/landscape、Split View、Stage Manager、键盘与导航状态保持；当前机器只有 iOS 27 iPhone runtime。
2. 在真实 OpenSubsonic / MoviePilot / AI 中转端点执行网络、音频、下载与 schema fallback；模拟器没有真实音频与锁屏媒体控制证明。
3. 对 500/1,000/10,000 首队列执行长时播放、后台恢复、重复 occurrence 移动/删除/随机/重启矩阵；单元测试已覆盖窗口与重复项的关键纯逻辑，但没有伪造真实大库网络状态。
4. 继续维护本文件：每次断联后先读“状态、续接点、验证命令”，再查看 `git status`，不要把截图或 DerivedData 当作源代码变更。
