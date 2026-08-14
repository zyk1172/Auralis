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

## P2

### `MANUAL-VERIFY` Now Playing 不喜欢/收藏镜像与五键传输控制

【测试名称】不喜欢按钮位置与收藏严格镜像

【测试目的】验证“不喜欢”在标题左侧、收藏在标题右侧、两者严格镜像；播放控制仍只有五键。

【前置条件】真机；至少一首长歌名歌曲。

【Xcode Beta 操作步骤】打开 Now Playing。确认标题左侧有 `heart.slash` 不喜欢按钮、右侧有 `heart` 收藏按钮，两者距屏幕边缘、尺寸、命中区域（≥44×44）、symbol 大小完全镜像；标题仍以屏幕中心真正居中，长歌名滚动时不会滑到两个按钮下面。确认标题下方进度条、再下方仍然只有：播放模式 | 上一首 | 播放/暂停 | 下一首 | 更多，共五键；不喜欢按钮绝不在这一排。

【预期结果】严格镜像；标题居中；五键传输控制不变；长标题不覆盖按钮。

【失败时需要提供】播放页截图（普通与长歌名）、录屏。

### `MANUAL-VERIFY` 不喜欢行为与持久化

【测试名称】dislike 点击、持久化、不跳歌、不改队列

【测试目的】验证点击不喜欢状态立即变化、当前歌曲继续播放、队列不变、杀 App 后状态仍在。

【Xcode Beta 操作步骤】播放中点击 `heart.slash`：状态立即变为已标记不喜欢；当前歌曲继续播放（不自动下一首、不暂停）；打开队列确认顺序与内容不变。关闭播放页再打开状态仍在；杀 App 重开仍在。再次点击取消不喜欢，确认不再出现在自动推荐（随机/相似/智能队列/发现）。

【预期结果】不跳歌、队列不变、持久化；取消后恢复可被自动推荐。

【失败时需要提供】录屏、队列前后截图、重启后状态截图。

### `MANUAL-VERIFY` 收藏与不喜欢互斥

【测试名称】favorite/dislike 互斥与不恢复

【测试目的】验证收藏与不喜欢互斥：设置 dislike 自动取消收藏；点击收藏自动取消 dislike；取消 dislike 不恢复旧收藏。

【Xcode Beta 操作步骤】收藏一首歌 → 点不喜欢 → 收藏取消、不喜欢激活（服务器 star 同步为未收藏）。取消不喜欢 → 收藏不自动恢复。再次点击收藏 → 不喜欢自动取消、收藏激活。

【预期结果】任一时刻只可能是“收藏”或“不喜欢”之一；取消不喜欢不恢复旧收藏。

【失败时需要提供】状态流转截图、服务器收藏状态。

### `MANUAL-VERIFY` 自动推荐排除不喜欢

【测试名称】Hard Exclusion 全链路

【测试目的】验证 Agent 推荐、随机推荐、智能队列、相似歌曲、由此继续播放、首页发现都不再出现 disliked 歌曲。

【前置条件】标记至少 3 首 disliked。

【Xcode Beta 操作步骤】对 Agent 说“推荐几首”“随机播放”“生成智能队列”，播放一首歌后点“由此继续播放”，在首页“随机音乐/收藏里随便听/很久没听/从未播放”货架翻页；确认这 3 首都不出现。然后用搜索搜其中一首：仍能找到；点开专辑/歌单：仍显示；直接播放：仍可播放。

【预期结果】自动发现/推荐全部排除；搜索、浏览、显式播放不受影响；当前队列已有 disliked 不自动移除。

【失败时需要提供】各入口结果截图、搜索与显式播放截图。

### `MANUAL-VERIFY` 大众评价详情与评论来源

【测试名称】MusicBrainz / CritiqueBrainz / ListenBrainz 详情与真实评论

【测试目的】验证三行来源可点击进入详情；CritiqueBrainz 评论显示真实 excerpt/作者/评分/日期/来源/license；无评论显示“暂无评论”。

【前置条件】一首公开数据库常见歌曲、一首冷门/无评论歌曲。

【Xcode Beta 操作步骤】打开歌曲信息：确认 MusicBrainz / CritiqueBrainz / ListenBrainz 三行都可点击进入详情页。CritiqueBrainz 有评论时看到评论卡（作者、评分、日期、语言、摘要、来源、license；有 👍👎 时显示），sourceURL 存在时可打开原始来源；无评论时显示“暂无评论”，不得显示“查询失败”。断网再打开：显示“暂时不可用”而不是伪造数据。

【预期结果】详情真实、来源与 license 保留、无评论≠查询失败。

【失败时需要提供】详情页截图、Network 抓包、评论卡截图。

### `MANUAL-VERIFY` Agent 鉴赏引用真实歌词与大众证据

【测试名称】music_appreciate 歌词与大众评价分层

【测试目的】验证有歌词时引用真实歌词、无歌词时不编造；隐私关闭时不泄露歌词正文；大众评价只来自真实 Evidence。

【前置条件】一首有歌词歌曲、一首无歌词歌曲；AI 隐私中“允许发送歌词”开关。

【Xcode Beta 操作步骤】对两首歌分别执行歌曲鉴赏：有歌词时应出现“歌词可用”并正确引用；无歌词时明确标注歌词不可用且不编造；关闭“允许发送歌词”后，有歌词歌曲应标注“歌词存在但不发送正文”。确认【大众评价】只引用工具返回的真实来源；没有证据时逐字为“暂无可核验的大众评价数据。”。

【预期结果】歌词真实状态、无歌词不编造、隐私不泄露正文、大众评价有真实来源。

【失败时需要提供】完整鉴赏回复、开关状态、有无歌词说明。

### `MANUAL-VERIFY` macOS 设置：AI 大模型高级设置不重复

【测试名称】设置 → AI 助手 → 高级设置仅一份

【测试目的】验证 macOS 设置窗口“高级设置”（上下文窗口 / 单次输出上限）只出现一次，且修改后能被实际请求采用。

【Xcode Beta 操作步骤】打开设置（Command-,）→ AI 助手：确认“高级设置”分区只有一份，包含“上下文窗口”与“单次输出上限”两个 Stepper，没有重复分区。修改上下文窗口为 32768、输出上限为 4096；执行一次歌曲鉴赏或推荐索引 V2 批次，确认请求按新限制进行（如配置 DeepSeek 128K 模型时不再按 256K 假设）。再导出/导入一次设置备份，确认这两个值随备份恢复；用旧备份（无这两个字段）导入，确认回退到默认 256K / 16K。

【预期结果】只有一个“高级设置”分区；值生效；备份往返一致；旧备份兼容。

【失败时需要提供】设置页截图、请求日志、备份文件。

### `MANUAL-VERIFY` macOS 设置：公开音乐数据与推荐索引 V2

【测试名称】AI 助手页公开音乐数据与索引导入导出

【测试目的】验证 macOS 设置窗口可独立开关 MusicBrainz / CritiqueBrainz / ListenBrainz、清除公开数据缓存、重置音乐身份；推荐索引 V2 可查看状态并导入导出。

【Xcode Beta 操作步骤】打开设置 → AI 助手：关闭“启用公开音乐数据”，打开一首歌曲信息，确认 0 个公开音乐 API 请求且 UI 显示“公开音乐数据已关闭。”；重新开启三个来源后分别验证查询。推荐索引 V2：确认“已分类 x / x 首”“规则版本”“索引格式”；连接服务器后执行“开始/继续全量索引”，完成后“导出索引…”；在另一台设备连接同一 NAS 后“导入索引…”，确认分类立即出现且不重新调用 LLM。

【预期结果】隐私门控生效（关闭后 0 请求）；三来源可独立开关；导入导出统计正确、不导出凭据/NAS 地址。

【失败时需要提供】设置截图、Network 抓包、导入统计文案。

### `MANUAL-VERIFY` macOS 键盘与桌面播放器

【测试名称】Space 唯一播放路径、Command-F 聚焦搜索、底部播放器点击

【测试目的】验证 Space 不在输入框内误触发播放；Command-F 聚焦侧边栏搜索；点击底部播放条封面进入主内容正在播放页而不是 iOS 式弹窗。

【Xcode Beta 操作步骤】在主窗口无输入焦点时按 Space：应播放/暂停；在侧边栏搜索框输入文字时按 Space：应输入空格，不得触发播放/暂停（输入完成后按 Space 应恢复播放/暂停）；按 Command-F：搜索框出现并聚焦，可直接输入；按 Command-L：进入正在播放页；点击底部播放条左侧封面/标题：进入主内容“正在播放”页，不出现 640×680 的 iOS 式 NowPlaying Sheet。底部播放条左侧确认可操作“不喜欢 / 收藏”按钮，且不改变播放/暂停/上一首/下一首三键语义；无歌曲时“上一首 / 下一首”禁用状态与 `canGoPrevious` / `canGoNext` 一致。

【预期结果】输入框内 Space 始终是空格；非输入态 Space 正常播放/暂停；Command-F 真正聚焦搜索；底部播放器点击进入 Mac 正在播放页且无双重导航/弹窗。

【失败时需要提供】键盘操作路径、输入框焦点状态截图、播放器点击后截图。

### `MANUAL-VERIFY` macOS 搜索与服务器页

【测试名称】搜索结果 GlobalID 匹配与本地网络横幅降级

【测试目的】验证搜索歌曲/专辑/艺术家跳转正确（不跨服务器误匹配）；服务器页不再常驻“局域网访问”横幅。

【Xcode Beta 操作步骤】在侧边栏搜索框输入关键词：点击歌曲结果应播放对应歌曲（服务器 A 的歌曲不会误播服务器 B 的同名歌曲）；点击专辑结果进入专辑详情且显示真实封面；点击艺术家/最近播放的艺术家进入艺术家页。打开设置 → 服务器：确认不再有常驻的“局域网访问”横幅；断开服务器网络触发“连接失败”，若错误信息包含“本地网络”，应显示“打开本地网络设置”直达按钮。

【预期结果】搜索跳转按 serverID + remoteID 匹配；本地网络说明只出现在错误路径。

【失败时需要提供】搜索结果截图、跨服务器误匹配复现步骤、服务器页截图。

---

# macOS Clean-Slate UI Rebuild 人工验证

以下项目依赖真实 Mac GUI，标记为 `MANUAL-VERIFY`。所有页面分别在 1280×820 / 窄窗口 / 宽窗口 / 全屏 / Dark Mode / Light Mode 检查。判据：去掉 Auralis 文字后是否明显像 Apple 原生 macOS 音乐播放器。

## P0

### `MANUAL-VERIFY` 首页与窗口骨架

【步骤】打开 App：确认系统 Toolbar / Sidebar / Liquid Glass 由系统提供；Sidebar 分区（浏览/资料库/播放列表/Auralis）行高系统化、无自定义大按钮；首页只显示真实有数据的货架，无服务器卡片、无“继续播放”大卡片；窗口 900→1600 拖动自由缩放无横向溢出；侧边栏可折叠/展开。

【预期】第一眼接近 Apple Music for Mac；无 Card dashboard 风；无每页渐变背景。

### `MANUAL-VERIFY` Songs Table 与多选

【步骤】歌曲页：表头排序（标题/艺术家/专辑/时长/年份/流派/格式/收藏）、拖拽调整列宽、单击选中、⌘/Shift 多选、双击播放、右键菜单分组（播放/导航/私人状态/文件/资料）；当前播放行显示 accent + speaker 波形而非整行染色；收藏列 heart.fill 仅在收藏时突出。

### `MANUAL-VERIFY` 底部播放条与右侧面板

【步骤】确认 transport 组（Shuffle/Previous/Play/Pause/Next/Repeat）与曲目身份组（Artwork/Title/Artist/进度）与上下文组（Favorite/Lyrics/Queue/Volume）三组分离；播放条高度 72–82pt、系统 bar 背景；点击封面进入正在播放页；⌘⇧L 展开歌词（当前行高亮、点击行跳转、自动跟随）、⌘⇧Q 展开队列（双击播放、拖动排序、Delete 移除、清空）；窄窗口下时间文字与音量滑杆降级为按钮，transport 三键不被压缩。

### `MANUAL-VERIFY` Album / Artist / Playlist Detail

【步骤】专辑：Hero 封面 + 元数据 + Play/Shuffle/Favorite/More，按碟曲目表，底部年份/曲数/时长/格式；艺术家：名称 + 收藏 + 播放/随机 + 热门歌曲 + 专辑网格（无艺人照片时 2×2 mosaic）；歌单：前 4 首真实封面 2×2 mosaic + 曲目表；「加入队列」与「播放」语义不混淆（加入=追加，播放=替换）。

### `MANUAL-VERIFY` 搜索

【步骤】⌘F 聚焦 Toolbar 搜索框；空查询显示 Landing（最近搜索/浏览资料库/最近播放艺术家/常用歌单）；输入后结果分 歌曲/专辑/艺术家/歌单；点歌曲播放、专辑→专辑详情（真实封面）、艺术家→艺术家页、歌单→歌单详情；跨服务器同名歌曲不误匹配（serverID+remoteID）。

### `MANUAL-VERIFY` 键盘 / 无障碍

【步骤】Space 在搜索框/文本输入框内输入空格、不触发播放；非输入态 Space 播放/暂停；⌘←/⌘→ 上一首/下一首；⌃⌘F 全屏播放；⌘, 打开设置；VoiceOver 遍历 Sidebar/Table/播放条标签完整；Full Keyboard Access 键盘选择表格行；Reduce Motion / Reduce Transparency 下动画与材质正常。

### `MANUAL-VERIFY` 截图验收（目标 39）

【步骤】对 Home / Songs / Albums / Album Detail / Artist Detail / Playlist / Search / Lyrics Panel / Queue Panel / AI Assistant / Server / Settings 各生成 1280×820、窄窗口、宽窗口、Dark、Light 截图。逐张问“去掉 Auralis 文字后是否明显像 Apple 原生 macOS 音乐播放器”；答案是否则记录并返回修改。

【失败时需要提供】截图、窗口尺寸、系统外观模式。

---

# Mac Apple Music Parity（Round-2 人工验收）

逐页检查：Structure / Density / System Controls / Cards / Typography / Resize / Keyboard / Hover / Light-Dark。判据：去掉 Auralis 文字后是否像 Apple 原生 macOS 音乐播放器。

## P0

### `MANUAL-VERIFY` 导航与搜索

【步骤】Home「查看全部专辑」→ 进入专辑一级页（不是详情 push）；Search 浏览「歌曲/专辑/艺术家/流派/播放列表」→ 真正离开搜索进入对应一级页；Album/Artist/Playlist 卡片 → 详情 push 且 Sidebar 高亮不变。⌘F 聚焦系统搜索框；输入空格类内容不误触发播放；空查询显示 Landing（最近搜索/浏览资料库）；提交后历史记录出现；关闭搜索回到原页面。

### `MANUAL-VERIFY` 详情页滚动模型

【步骤】Album / Artist / Playlist / Genre 详情整页只有一个纵向滚动；曲目行 hover 显示 Play/More；行高约 34–38；双击行播放；右键菜单完整；无嵌套 Table 造成的双层滚动。

### `MANUAL-VERIFY` Full Screen Player / MiniPlayer

【步骤】播放一首歌 → 菜单 窗口→全屏播放（⇧⌘F）：先出现沉浸播放器再进入系统全屏；背景为整窗 Artwork 派生（无矩形边界/无霓虹）；Esc 退出全屏不退出 App；无 MusicBrainz/码率等 Dashboard 信息。菜单 窗口→迷你播放器（⌥⌘M）：独立小窗，封面+标题+进度+控制+音量；「隐藏封面」切紧凑；播放状态与主窗口一致。

### `MANUAL-VERIFY` Player Bar 三区

【步骤】Shuffle/Previous/Play/Next/Repeat 为 LEFT；当前歌曲 Artwork/Title/Artist/进度 为 CENTER 且视觉居中；Favorite/Lyrics/Queue/Volume 为 RIGHT。窄窗口先隐藏时间文字与音量滑杆（音量变按钮），transport 三键不压缩。

### `MANUAL-VERIFY` Lyrics / Queue / Get Info

【步骤】⌥⌘L 打开歌词：普通行 18pt、当前行 23pt 高亮；行距充足；点击 timed 行 seek；自动滚动只在当前行变化时。⌥⌘U 打开队列：正在播放 / 播放下一首 / 历史记录 三段；清空只清待播保留当前；拖动/Delete 只作用待播。⌘I Get Info：TabView 五页（详细信息/插图/歌词/文件/Auralis），Auralis 页含公开音乐三来源与歌曲鉴赏；不显示服务器凭据/私有 URL。

### `MANUAL-VERIFY` Sidebar 编辑 / 新建歌单 / 艺术家 split

【步骤】Sidebar「资料库」hover 出现「编辑」：显示/隐藏 最近添加/艺术家/专辑/歌曲/流派/下载，拖动排序，重启后保持。文件 → 新建播放列表（⌘N）：输入名称创建，Sidebar 播放列表立即出现。艺术家页为左侧列表 + 右侧详情：选择艺术家即显示详情；窄窗口 split 可拖动分隔。

### `MANUAL-VERIFY` 外观与 Tiles

【步骤】Light/Dark 切换跟随系统（不强制 Theme）；Sidebar/Toolbar/Search/Inspector 用系统材质（Liquid Glass 由系统提供）；Home 最近播放/最近添加显示专辑（去重封面）；收藏为紧凑歌曲列表；Playlist 封面为真实 2×2 mosaic（4 首不同封面）；Album/Artist/Playlist 卡片视觉区分（Artist 圆形/mosaic，非方形专辑卡）。

### `MANUAL-VERIFY` 键盘 / 无障碍

【步骤】Space 播放暂停（输入框内为空格）；Return 播放选中曲目；←/→ 上一首/下一首；⌘↑/⌘↓ 音量；⌘I 信息；⌥⌘U 队列；⇧⌘F 全屏播放；⌥⌘M 迷你播放器；⌘, 设置。VoiceOver 遍历 Sidebar/Table/播放条/Get Info；Play/More 可通过右键与键盘访问（非 hover-only）；当前歌词 accessibilityValue=“当前歌词”；收藏/不喜欢有 symbol + accessibility state。

---

# Round-3 人工验收（崩溃修复 + 首页/播放条/助手/Mosaic）

## `MANUAL-VERIFY` 崩溃回归（P0）

【步骤】全部在已推送的当前构建上执行：

1. **打开 AI 助手**：Sidebar →「Auralis」→「AI 助手」。预期：正常进入，不闪退；输入框在页面底部、位于悬浮播放条上方，二者不重叠；页面背景为系统外观（不再出现主题色大色块）。
2. **歌曲鉴赏**：任意歌曲右键 →「歌曲鉴赏」→ 应跳转到 AI 助手并发起鉴赏，不闪退。
3. **点击海报展开播放器**：底部悬浮播放条点击封面（或空白区域）→ 展开播放器，不闪退；展开后左上角出现关闭胶囊、右上角音量胶囊；窗口顶部三颗交通灯仍可见。
4. **迷你播放器**：⌥⌘M 打开独立迷你窗口，不闪退；关闭后可再次打开。

## `MANUAL-VERIFY` 首页 / 侧边栏切割

【步骤】打开首页，预期只出现以下货架（全部为网格卡片，无列表行）：
最近播放专辑 / 最近添加专辑 / 常听专辑 / 常听艺术家 / 很久没听 / 从未播放 / 收藏里随便听。

- 首页**不再**出现「收藏」列表行与「播放列表」货架（侧边栏「播放列表」区已有 收藏歌曲 / 所有播放列表）。
- 侧边栏「资料库」区照常：歌曲 / 专辑 / 艺术家 / 流派 / 下载 / 最近添加 / 最近播放。

## `MANUAL-VERIFY` 播放条（Apple Music 式）

【步骤】
- 高度明显变矮（≈68pt），内容垂直居中；**封面 / 标题 / 艺术家区域**点击即展开播放器（不再给整条 capsule 挂 TapGesture，避免 macOS 上祖先手势吞掉内部按钮）。
- 传输按钮（随机 / 上一首 / 播放暂停 / 下一首 / 循环）必须各自响应：逐个点击验证。
- 展开动画为**自底部向上覆盖整个页面**（+淡入），不再是封面放大/缩放感。
- 展开页顶部留白明显减少；左上关闭胶囊、右上音量胶囊贴近顶栏（与窗口交通灯同一视觉行）。
- 收起（关闭）动画为下滑消失。

## `MANUAL-VERIFY` 播放列表封面 Mosaic

【步骤】找一首 2/3/4 首不同封面（或不同专辑）的歌单：卡片封面应为 2×2 均分格子（每格约半尺寸），4 张图各占一格、不再叠在一起；1 张封面时整卡显示。

## `MANUAL-VERIFY` 不喜欢页 / 短页面播放条位置

【步骤】进入「不喜欢」页（1–3 首）：底部悬浮播放条应贴在窗口底部（不浮动到页面中部）；页面底部与播放条之间留出可读间距。若在特定窗口高度下仍观察到播放条悬浮异常，记录窗口尺寸回报。

## `MANUAL-VERIFY` 歌词

【步骤】播放有歌词的歌曲 → 点击播放条「歌词」按钮（或 ⌥⌘L）：右侧面板打开并显示歌词（普通行 18pt、当前行 23pt 高亮、点击 timed 行 seek）；无歌词歌曲显示「暂无歌词」。若你的服务器不返回歌词，预期为「暂无歌词」而非白屏/无反应。

---

## Repeat / Shuffle Production Regression

> 状态：`MANUAL-VERIFY`（真实 Mac + 真实流媒体，无法在无头/单元测试环境驱动 AVPlayer 播完事件）。
> 自动侧已由 `PlaybackModeBehaviorTests`（24 项）覆盖模型层语义；这里验证真实引擎与交互。
> 核对日期：2026-08-13（macOS 27 Beta 5 / Xcode 27 Beta）。

前置：连接真实 Navidrome/OpenSubsonic 服务器，播放列表 ≥ 3 首真实歌曲；每步观察“当前曲目是否按预期变化/重播”。

### CASE 1 单曲循环（自然播完重播）
- 顺序播放一首歌 → 开启「单曲循环」→ 等待自然播完。
- 预期：当前曲目从头重新播放（不是下一首）；可连续多次循环。

### CASE 2 单曲循环 + 预载竞态（歌曲尾部切模式）
- 顺序播放，让某首歌只剩最后 1～2 秒 → 此时才点「单曲循环」→ 等待自然播完。
- 预期：当前曲目从头重新播放；不会因为旧预载项被引擎带入而跳到下一首。

### CASE 3 列表循环（队尾绕回）
- 开启「列表循环」，播到队列最后一首 → 自然播完。
- 预期：绕回第一首继续播放。

### CASE 4 不循环（队尾停止）
- 保持「不循环」，播到队列最后一首 → 自然播完。
- 预期：播放停止（停留在最后一首，不切歌、不绕回）。

### CASE 5 Shuffle + Repeat Off（一轮即停）
- 开启「随机播放」并确认循环为「不循环」→ 记录队列曲目数 N。
- 预期：连续随机播放直到每首约出现一次；一轮完成后**自动停止**，不再开始第二轮；此时「下一首」按钮应置灰。

### CASE 6 Shuffle + Repeat All（多轮继续）
- 开启「随机播放」+「列表循环」→ 播放 ≥ 两轮。
- 预期：每轮都能继续随机，不停止。

记录：如果任何 CASE 与预期不符，请记录复现步骤、窗口尺寸、当前曲目与队列快照（不含服务器凭据）。


### 传输按钮可点性回归（2026-08-13 修复）
- 修复前：整条悬浮播放条挂 `.onTapGesture { 展开播放器 }`，macOS 上祖先 TapGesture 会与内部 Button/Menu/Slider 命中测试冲突，导致循环/随机/切歌按钮偶发点不动（表现为“循环播放不起作用”）。
- 修复后：移除整条手势；展开播放器只由封面与标题/艺术家文本按钮触发；传输按钮无祖先手势干扰。
- 运行验证：Debug 构建下执行 `log stream --predicate 'process == "Auralis"'`，点击「循环模式」/「随机播放」应输出 `action cycleRepeat …` / `action toggleShuffle …`。
- 检查项：
  - 播放条上「随机」「上一首」「播放/暂停」「下一首」「循环」「收藏」「歌词」「队列」「音量」逐个点击均有响应，且点击后不展开播放器（除非点在封面/标题上）。
  - 循环按钮点击三次应依次显示：不循环 → 列表循环 → 单曲循环（帮助文本/图标变化）。

---

# Release Candidate 深度审计（2026-08-14）真机验收

以下为 RC 审计新增/强调的 MANUAL-VERIFY。命令行与模拟器不能代替真机播放引擎、窗口与后台行为。

## RC-1 播放边界（AVQueuePlayer）真机验收
- 背景：循环/无缝切歌已改为 `PlayerItemBoundaryCoordinator` 确定性边界状态机
  （`AVQueuePlayer.currentItem` KVO 是推进权威事件；不再用 `Task.yield` 猜测）。
  确定性逻辑已由 `PlayerItemBoundaryCoordinatorTests`（9 项）与
  `AURALIS_RUN_AV_TESTS=1 swift test --filter AVFoundationPlaybackEngineBoundaryTests`
  覆盖；以下为真机最终确认。
- 前置：iPhone（iOS 27）/ iPad / Mac 各一台；≥3 首真实可播放队列。
- iPhone 前台/锁屏/后台、控制中心；iPad 前台/分屏；Mac 普通窗口/Expanded/Mini/全屏。
- 每平台至少：
  - Repeat One：同一首连续重播 ≥ 3 次，每次 position 归 0、进入 playing；
  - Repeat All：3 首连续播放 ≥ 2 圈，队尾 C → A 无缝（无第二段 AVPlayer 重建间隙）；
  - Repeat Off：一轮播完停止（不绕回、不重复）；
  - Shuffle + Repeat Off：一轮随机播完停止；Shuffle + Repeat All：第二轮继续；
  - 后台自然播完（App 在后台/锁屏 30 分钟）：循环仍按 Repeat 模式继续，不依赖 SwiftUI 生命周期。
- 关键检查：A → B 无缝推进时**不会**先 `trackEndedHandler` 再 `preparedStartedHandler`
  （无双重推进）；控制中心/锁屏标题与声音一致（声音已到 B，显示必须也是 B）。
- 失败时提供：Console 中 `AuralisStartup`/播放日志、复现步骤、系统版本、音频格式。

## RC-2 Mac Expanded Player 标题栏
- 连续「普通资料库 → Expanded → Collapse」≥ 30 次。
- Expanded 时：左上角绝无「澜音」、无原生窗口标题、标题栏透明、自定义 traffic lights 正常；
- Collapse 后：普通窗口 traffic lights 恢复、toolbar/sidebar/navigation title 正常、窗口可拖动/缩放/最小化/关闭；
- 全屏进出后同样正确；Mini Player 不受影响；播放进度 tick 不重排 titlebar。
- 逻辑已由 `MacExpandedChromeTests`（8 项）覆盖；此处为真窗口视觉确认。

## RC-3 iPad Sheet 仲裁
- 打开 Browse 详情时点 MiniPlayer：只出现 Now Playing，Browse 关闭；
- 从 Now Playing 打开 Browse 链接：Now Playing 关闭，只出现 Browse；
- 上述任一生效时触发服务器设置（助手/快捷指令/连接错误路径）：只出现一个 sheet，关闭后恢复原 sheet；
- Siri/快捷指令在 Browse 打开时触发 Now Playing：不得双 sheet。
- 逻辑已由 `PadPresentationArbitrationTests`（14 项）覆盖；此处为真机确认。

## RC-4 Live Activity / 灵动岛 / 小组件
- 首次播放后：灵动岛出现当前歌曲（标题/艺术家/进度/播放状态）；
- 切歌/暂停/继续/拖动：灵动岛与锁屏信息跟随，节流更新（约 5s）不报错；
- 停止/队列结束/移除服务器：活动结束，小组件回到「暂无播放」；
- 桌面小组件（Home Screen）显示与 App 一致的「正在播放」快照。
- 前置：iOS 27 真机；小组件/灵动岛需要在真机验证（模拟器不可替代）。

## RC-5 流失败与跨服务器身份
- 播放中把服务器流地址失效（NAS 断网/换 URL）：自动刷新重试 ≤ 2 次后按队列策略前进/绕回/停止，不无限自旋；
- 播放中切换服务器：播放条立即切到新服务器曲目（不再显示旧服务器标题）；点播放不会去新服务器拉旧 TrackID 的音频；
- 下载进行中切换服务器：旧下载取消并标记失败（不把新服务器音频写入旧服务器缓存）。
- 逻辑已由 `PlaybackPolicyRegressionTests`（4 项）覆盖；此处为真机/真实 NAS 确认。
