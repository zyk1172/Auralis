# Auralis 性能基线与验证方法

## 本次静态基线

本轮没有伪造耗时、FPS 或内存数字。命令行环境无法替代 Xcode Beta 真机 Instruments，
因此这里只记录可由源码确认的结构边界和已经实施的修复，数值基线留给下述真机流程。

已经存在并保留：

- `PlaybackStore` 局部发布播放位置与状态，避免整页订阅巨型 Model；
- `ArtworkStore` 使用缩略图/大图两组有界 `NSCache`，并处理 memory pressure；
- `ArtworkPipeline` 合并相同请求；
- ImageIO 按目标像素下采样，不在 SwiftUI View 中解码原图；
- `ArtworkDiskCache` 是 actor，磁盘访问不在 MainActor；
- `HomeSnapshotBuilder` 一次构建查找表并复用排序结果；
- Dock 滚动状态使用局部 Environment/Store 传播，而非每帧发布整个 AppModel。

本轮确认并修复：

- 万首曲库的首页快照曾在 `@MainActor` 同步执行多轮 filter/sort。现在小集合保持同步
  语义，大于等于 2,000 首时在 utility detached task 计算，以 generation/cancellation
  防止旧快照覆盖新目录；
- 搜索页的歌曲、专辑、艺术家和歌单 computed property 会在空态判断和列表构建时
  重复扫描。现在一次 body 只生成一份 `LocalResults`；150ms 输入防抖继续保留；
- Agent 统计曾在播放次数循环内反复 `first(where:)` 扫全库，形成 O(play-count × library)
  行为。现在每次统计先建立 TrackID 查找表；
- 本地网络 TCP 探测超时只结束 continuation、未结束 `NWConnection`。现在超时同步取消
  connection，释放 state handler 与计时器引用链；
- 封面缓存容量、不可用负缓存与波纹数组均有明确上限；未发现无限增长容器；
- NotificationCenter memory-pressure observer 的 token 由独立持有者在释放时清理。

## 真机 Instruments 基线

MANUAL-VERIFY: Xcode Beta Build/Test。使用 Xcode Beta 打开项目，选择用户实际 iPhone，
以 Release 配置运行。每项录制前强制退出 App，不清数据库或封面缓存；冷启动与热启动
分别录制，结果注明设备、系统、曲库歌曲数、缓存是否命中、连接是 LAN 还是 WAN。

### SwiftUI Instrument

1. Product → Profile，选择 SwiftUI；
2. 记录冷启动到首页稳定；
3. 首页连续快速滚动 30 秒；
4. 进入音乐库，在歌曲、专辑、艺术家、分类之间切换并高速滚动；
5. 播放中重复首页/音乐库/AI 助手切换；
6. 标记异常 body update、长 update group 和重复 view identity；
7. 对比“无封面命中”和“磁盘缓存命中”两轮。

### Time Profiler

分别录制：

- 冷启动与 SQLite Catalog 恢复；
- 同步完成后首页快照刷新；
- 搜索框连续输入与删除；
- 首页、音乐库高速滚动；
- 打开 Now Playing、歌词、队列并返回首页。

检查 Main Thread 的 self time，重点关注排序、字符串本地化匹配、图片解码、JSON/磁盘 IO
与 `objectWillChange`。保存 trace 后再填写具体毫秒数据，不根据肉眼猜测。

### Core Animation

开启 Hitches、FPS 和 Color Blended Layers，录制：

- Dock 展开/收拢；
- 首页带封面横向滚动；
- Now Playing 海报与环境光；
- 歌词滚动。

记录 hitch 时间点并回到 Time Profiler 对齐调用栈。液态玻璃本身的透明叠层不能只因
“ blended” 就判定错误，必须结合 hitch 和 GPU 时间。

### Allocations / Leaks

循环 10 次：打开/关闭 Now Playing、歌词、队列、AI 会话面板、服务器设置。然后观察：

- `ArtworkStore`、图片对象与 decoded bytes 是否回落；
- SwiftUI View/Task 是否持续累积；
- `NWConnection`、DispatchSourceTimer、Notification observer 是否留存；
- 播放切歌 50 次后 player item/observer 是否稳定。

### Network

分别在 LAN、WAN 和已有缓存下记录：

- 冷启动 Catalog 是否不必要重复拉全库；
- 同一封面尺寸是否合并请求；
- 列表缩略图是否请求目标尺寸而非原始大图；
- 播放、下一首预取、歌词和封面请求是否能按用途区分；
- 从 Wi-Fi 切蜂窝后是否只恢复必要请求。

## 建议记录表

每个场景记录：设备/OS、曲库规模、配置、冷/热、持续时间、峰值 RSS、主线程最重调用、
hitch 数、网络请求数、异常 retain 类型、trace 文件名。第一次实测结果作为 baseline；后续
只有同条件重复三次后才比较趋势。
