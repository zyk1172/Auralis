# Manual validation

以下项目统一标记为 `MANUAL-VERIFY`。它们依赖真机、真实 NAS、音频路由、iOS 后台策略或 Instruments，不能由命令行单元测试或模拟器诚实替代。优先级按故障影响排列。

## P0

### `MANUAL-VERIFY` 播放生命周期、后台与恢复

【测试名称】长时间播放与系统控制恢复

【测试目的】验证前台/后台/锁屏播放、队列推进、暂停重启恢复和系统控制中心没有重复或跳曲。

【前置条件】iPhone 真机；Xcode Beta；真实 LAN/WAN 音乐服务器；至少 30 首可播放队列。

【Xcode Beta 操作步骤】以 Release 配置运行，依次播放/暂停/seek；连续播放 30 首；后台和锁屏 30 分钟；从控制中心执行播放、暂停、上一首、下一首和 seek；暂停后强制退出并重启；分别验证 Off、Repeat One、Repeat All、Shuffle 和四种睡眠计时。

【预期结果】音频不中断；队列没有重复/跳项；锁屏信息与 App 一致；暂停重启不自行播放；循环、随机和计时行为与 UI 状态一致。

【失败时需要提供】Console、锁屏和播放页截图、发生前后的队列、系统版本、音频格式、操作路径；若卡死，附 Time Profiler。

### `MANUAL-VERIFY` 网络切换与离线恢复

【测试名称】LAN/WAN、NAS 故障和本地下载回退

【测试目的】验证并行端点探测、流地址刷新、目录离线可用和恢复逻辑不会重复启动播放。

【前置条件】同一服务器可从 LAN 与 WAN 访问；5G；至少一首已下载歌曲。

【Xcode Beta 操作步骤】播放时在 Wi-Fi 与 5G 间双向切换；分别中断 LAN、WAN 和 NAS；重启 Navidrome；等待旧流地址失效后继续播放；断开 NAS 播放已下载歌曲；边播放边下载多首歌曲；取消一个正在恢复的后台下载。

【预期结果】内网可用时使用内网；仅内网失败时使用外网；恢复不重复播放；服务器不可用时本地目录仍可浏览、已下载歌曲可播放；取消的下载不会被后台恢复回调重新标记为下载中。

【失败时需要提供】Console、Network Instruments、当前网络类型、LAN/WAN 地址类型（隐藏凭据）、服务器日志、下载状态截图和精确操作时间线。

### `MANUAL-VERIFY` 中断与音频路由

【测试名称】电话/Siri/耳机/AirPlay 路由

【测试目的】验证系统中断和路由变化遵守 iOS 音频会话政策。

【前置条件】真机；有线耳机或 AirPods/蓝牙设备；可用 AirPlay 目标。

【Xcode Beta 操作步骤】播放时触发来电和 Siri；拔出有线耳机、断开蓝牙；在扬声器、耳机、蓝牙和 AirPlay 间切换；前后台各执行一轮。

【预期结果】中断按系统 `shouldResume` 决定恢复；耳机断开时暂停而不是意外外放；控制中心与 App 状态一致。

【失败时需要提供】Console、音频路由名称、前后台状态、控制中心与播放页截图、操作路径。

## P1

### `MANUAL-VERIFY` Gapless 与 ReplayGain

【测试名称】无缝衔接和响度增益听测

【测试目的】验证 best-effort seamless 边界与 Track/Album ReplayGain，不宣称样本级无缝。

【前置条件】同编码本地 FLAC 现场专辑、连续古典乐章、DJ Mix、概念专辑；含/不含 ReplayGain 与 peak 标签的测试曲；LAN 原始流和 WAN 转码流。

【Xcode Beta 操作步骤】对本地、LAN 未转码、WAN 转码逐组连续播放；在预缓冲前移动/删除下一首并手动 Next；切换 Shuffle/Repeat；确认无 crossfade；分别试听 ReplayGain Off、Track、Album、无标签、正增益 peak protection 和本地/远程同曲。

【预期结果】本地与未转码来源尽量无可感知缝隙；WAN 限制如实记录；不重叠音频；Off 不改变增益，Track 均衡跨曲响度，Album 保留专辑内部动态，无标签保持 unity，peak protection 不削波。

【失败时需要提供】音频样本、codec/container、是否转码、路由、发生时间点、队列编辑动作、Console 与录屏。

### `MANUAL-VERIFY` 外部音乐身份、大众评价与隐私边界

【测试名称】MetaBrainz 按需增强

【测试目的】验证歌曲信息与歌曲鉴赏只按需请求 MusicBrainz、CritiqueBrainz 和 ListenBrainz，来源分别展示，失败时不伪造大众评价。

【前置条件】真机可访问互联网；一首公开数据库常见歌曲和一首私人/冷门录音。

【Xcode Beta 操作步骤】启动后停留首页一分钟观察网络；打开常见歌曲“更多操作 → 歌曲信息”；关闭后立即再次打开；从 AI 助手执行歌曲鉴赏；对冷门歌曲重复；断网再执行一次。

【预期结果】启动时没有整库外部请求；只查询当前歌曲；MusicBrainz、CritiqueBrainz、ListenBrainz 与“我的评分”分别显示且没有综合分；缓存命中不重复请求；无数据时显示“暂无可核验的大众评价数据。”；请求不含凭据、流地址、歌词或完整曲库。

【失败时需要提供】Console、Network Instruments、歌曲信息页截图、歌曲标题/艺人/版本、AI 完整回复和操作路径。

### `MANUAL-VERIFY` Apple UI、Dock 与辅助功能

【测试名称】导航、Liquid Glass 和无障碍

【测试目的】验证 iPhone/iPad/macOS 导航语义、Dock 连续形变、键盘避让和辅助功能路径。

【前置条件】iPhone、iPad（含 Split View）和 Mac；Xcode Beta；开启 VoiceOver、动态字体、Reduce Motion、Reduce Transparency、Increase Contrast 的能力。

【Xcode Beta 操作步骤】依次进入专辑/艺术家/歌单/分类详情并边缘返回；上下滚动切换 Dock；打开/关闭键盘并旋转/调整 Split View；VoiceOver 遍历首页、音乐库、AI 助手、正在播放和设置；逐项切换无障碍选项；macOS 用 Full Keyboard Access 遍历侧边栏、内容和播放条。

【预期结果】没有 modal 伪导航；Dock 单次手势只切换一次且方向正确；玻璃材质连续；Reduce Motion 无弹跳，Reduce Transparency 使用可读实色；所有图标有动作名称且点击区至少 44pt；键盘不遮挡输入框。

【失败时需要提供】录屏、截图、设备/系统、辅助功能设置、操作路径；动画卡顿附 Core Animation/SwiftUI trace。

## P2

### `MANUAL-VERIFY` 性能、内存与封面管线

【测试名称】万首曲库冷/热启动和两小时稳定性

【测试目的】建立真实 baseline，验证大曲库不在 MainActor 重算、封面下采样/有界缓存和观察者生命周期。

【前置条件】约 8,000–10,000 首真实曲库；冷缓存和热缓存各一轮；Xcode Beta Instruments。

【Xcode Beta 操作步骤】用 SwiftUI、Time Profiler、Core Animation、Allocations/Leaks、Network 分别录制冷/热启动；首页/音乐库高速滚动 30 秒；连续搜索输入；反复打开/关闭 Now Playing、歌词、队列、AI 会话和设置各 10 次；切歌 50 次；连续播放两小时并触发一次 memory pressure。

【预期结果】首页与搜索无长时间主线程排序/IO；封面按目标尺寸请求且相同请求合并；内存压力后缓存可回落；Task、observer、NWConnection、player item 不持续累积；不以主观感受填写 FPS 或百分比。

【失败时需要提供】全部 `.trace`、设备/OS、曲库规模、冷/热、LAN/WAN、峰值 RSS、hitch 时间点、最重调用栈和复现路径。

### `MANUAL-VERIFY` Agent 真实模型与长任务

【测试名称】OpenAI 原生/兼容接口、多轮工具和推荐索引完整构建

【测试目的】验证真实服务的 tool-call 配对、任务预算、停止条件、隐私授权、取消与重启中断恢复。

【前置条件】分别配置 OpenAI 原生 Responses 与兼容 Chat Completions；测试服务器曲库；索引存在待分类项。

【Xcode Beta 操作步骤】分别执行播放一首、建立 20 首队列、修改歌单、歌曲鉴赏、服务器诊断、一次性完成索引 V2；观察多轮工具结果；取消一次运行中任务；执行副作用后强制退出并重启；检查会话和操作日志。

【预期结果】tool_call_id 与 tool result 严格配对；成功副作用不重复；真实有进展时不因低工具次数中止；无进展/重复/超时按结构化原因停止；索引只有 pending=0 才完成；重启任务标记 interrupted 且不重放动作；凭据和完整曲库不进入 Prompt/日志。

【失败时需要提供】脱敏后的请求/响应、Agent 会话导出、操作记录、任务状态、Console、模型/接口类型和完整操作路径。

### `MANUAL-VERIFY` 公开音乐数据总开关与隐私边界

【测试名称】公开音乐数据开关与 0 请求

【测试目的】验证“公开音乐数据”总开关与 MusicBrainz / CritiqueBrainz / ListenBrainz 三个独立开关真正控制网络请求；关闭时不是 UI 隐藏而是 0 个网络请求。

【前置条件】真机可访问互联网；一首公开数据库常见歌曲。

【Xcode Beta 操作步骤】设置 → Agent → 公开音乐数据，关闭总开关；打开该歌曲“更多操作 → 歌曲信息”。预期页面显示“公开音乐数据已关闭。”；用 Network Instruments 确认 0 个 MusicBrainz / CritiqueBrainz / ListenBrainz 请求。然后只开 MusicBrainz 重复一次，确认只有 MusicBrainz 被访问；再分别只开 CritiqueBrainz、ListenBrainz 重复。最后全部开启并再次打开歌曲信息，确认三个来源分别显示、没有综合分；点击“清除公开音乐数据缓存”后再次打开会重新请求（而非一直命中旧缓存）。

【预期结果】总开关关闭时 0 个公开音乐 API 请求；单独关闭某个来源时该来源 0 请求；disabled 与 noData 是两种不同文案（“公开音乐数据已关闭。” vs “暂无可核验的大众评价数据。”）；请求失败显示“公开音乐数据暂时不可用。”而不是伪造数据。

【失败时需要提供】Console、Network Instruments 抓包、歌曲信息页截图、开关状态、操作路径。

### `MANUAL-VERIFY` ListenBrainz 收听量字段来源

【测试名称】Listen Count 与 Listener Count 来自 popularity 接口

【测试目的】验证歌曲信息页的 ListenBrainz 数据来自 `/1/popularity/release-group`（或 recording fallback）的 `total_listen_count` / `total_user_count`，而不是用 top listener 数量冒充总听众。

【前置条件】真机可访问互联网；一首能匹配到 release-group MBID 的常见歌曲；Network Instruments。

【Xcode Beta 操作步骤】打开歌曲信息，确认 ListenBrainz 显示“收听次数”与“听众数”两个独立数字；用 Network Instruments 确认请求为 `POST https://api.listenbrainz.org/1/popularity/release-group`（JSON `{"release_group_mbids":[...]}`）并返回 `total_listen_count` / `total_user_count`。对只有 recording MBID 的冷门歌曲确认 fallback 到 `POST /1/popularity/recording`。

【预期结果】显示的是总收听量与总用户数（不同来源字段）；不使用 topListeners.count 冒充总听众；请求体只包含一个 MBID，不含任何私人数据。

【失败时需要提供】Network Instruments 请求/响应、歌曲信息页截图、歌曲标题/艺人/版本。

### `MANUAL-VERIFY` Now Playing 封面环境光

【测试名称】封面动态环境光视觉回归

【测试目的】验证环境光主光源来自真实封面模糊副本，不再出现“封面后面多一层矩形彩色框”，且不被页面边缘裁成方框。

【前置条件】真机；分别准备黄色、黑色、红色、蓝色、多彩封面与无封面歌曲。

【Xcode Beta 操作步骤】依次播放上述封面歌曲并停留播放页：观察封面周围光效是否从封面本身向四周扩散；切换歌词/队列页再切回播放页，确认光效不盖住歌曲标题且不改变布局；播放中观察缓慢呼吸（约 3~5 秒周期、幅度小）；暂停后确认呼吸停止、只留弱静态光；开启“减少动态效果”后确认呼吸动画完全静止；检查页面上下边缘没有被裁出的水平亮线/方框。

【预期结果】无矩形彩色底板；光源颜色来自当前封面；Glow 不被页面边缘裁成方框；封面本体只有轻微中性阴影；呼吸动画自然缓慢；暂停静止；Reduce Motion 正常；切歌时颜色平滑过渡。

【失败时需要提供】各封面播放页截图与录屏、设备/系统版本、Reduce Motion 状态。

### `MANUAL-VERIFY` 推荐索引 V2 跨设备导入导出

【测试名称】同一 NAS 两台设备共享 V2 索引

【测试目的】验证设备 A 导出的 `.auralis-index-v2` 可在设备 B（连接同一 NAS、本地 ServerID 不同）导入，且不再重新调用 LLM 分类。

【前置条件】两台真机/一台真机 + Mac；同一 Navidrome 服务器；设备 A 已有完整 V2 索引。

【Xcode Beta 操作步骤】设备 A：设置 → Agent → 推荐索引 V2 → 导出索引…，保存 `.auralis-index-v2` 文件（确认只导出“已分类”条目）。设备 B 连接同一 NAS 并完成目录同步后：导入索引… 选择该文件。预期显示结构化统计（成功导入 / 已存在 / 歌曲已变化 / 当前音乐库不存在 / 格式错误）。随后打开资料库“分类”页确认标签立即可用，并观察网络/日志确认没有重新发起 LLM 分类。然后修改设备 A 上一首歌的 title，重新导出并导入设备 B：该歌应被拒绝并保持 pending，其余歌曲正常导入。

【预期结果】分类导入后立即可用且不调用 LLM；不同本地 ServerID 仍能正确匹配（remoteTrackID + contentHash）；title 变化的歌曲被标记“歌曲已变化”保持 pending；导入不改变收藏/评分/播放次数等私人数据；索引文件内不含服务器密码、token、NAS URL、播放地址、歌词或播放历史。

【失败时需要提供】导出文件结构（脱敏）、导入统计截图、分类页截图、Console/网络日志、两台设备 ServerID 差异说明。

### `MANUAL-VERIFY` OpenAI 兼容模型能力配置

【测试名称】上下文/输出上限按模型配置

【测试目的】验证不同 OpenAI 兼容端点（OpenAI / DeepSeek / OpenRouter / Ollama / LM Studio）可按实际模型修改上下文窗口与单次输出上限，且长任务不会因为预算与 Provider 上限混淆而失败。

【前置条件】真机；至少一个 OpenAI 兼容端点（如本地 Ollama 或 DeepSeek）；一个上下文窗口小于 256K 的模型。

【Xcode Beta 操作步骤】设置 → Agent → 配置大模型 → 高级设置：把“上下文窗口”改为该模型实际值（如 32K/64K）、“单次输出上限”改为合适值；保存后跑一次歌曲鉴赏与一次推荐索引 V2 批次。再导出/导入一次设置备份，确认这两个值随备份恢复；用旧备份（无这两个字段）导入，确认回退到默认 256K / 16K。

【预期结果】请求不会因超 Provider 上下文窗口被 API 拒绝；任务累计预算、单轮输入限制、单轮输出限制互不混淆；备份/恢复正确，旧备份兼容。

【失败时需要提供】请求/响应脱敏日志、设置页截图、备份文件（加密）往返结果、模型名称与真实上下文窗口。

### `MANUAL-VERIFY` 设置页版本号

【测试名称】版本号来自 Bundle

【测试目的】验证设置“关于”页显示 `1.0.2 (3)` 这类来自 `CFBundleShortVersionString (CFBundleVersion)` 的版本，而不是硬编码旧版本号。

【Xcode Beta 操作步骤】打开 iOS 设置 → 关于 与 macOS 设置窗口 → 关于；与 `project.yml` 的 `MARKETING_VERSION: 1.0.2`、`CURRENT_PROJECT_VERSION: 3` 对比。

【预期结果】iOS 与 macOS 均显示 `1.0.2 (3)`（或与工程设置一致的值）；修改工程版本后设置页同步变化，无硬编码残留。

【失败时需要提供】设置页截图、project.yml 版本配置。
