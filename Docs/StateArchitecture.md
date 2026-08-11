# Auralis 状态架构

## 目标

`AuralisAppModel` 是 App 级协调器，不再作为所有页面数据的唯一存储位置。播放状态仍只有一个真实来源：`PlaybackStore`。SwiftUI、Agent、系统媒体集成与 App Intents 不创建平行播放状态。

## 领域 Store

| Store | 拥有的状态 | 不负责 |
| --- | --- | --- |
| `PlaybackStore` | 当前曲目、队列、进度、播放/暂停、循环与随机 | 资料库同步、下载、首页投影 |
| `ArtworkStore` | 有界内存封面缓存与管线 | 资料库事实、页面导航 |
| `HomeStore` | 首页布局偏好、各首页货架投影、快照取消与 generation | 全局目录写入、播放 |
| `LibraryStore` | 当前目录与浏览页加载投影 | 服务器凭据、音频播放 |
| `ServerStore` | 连接状态、认证失败状态、能力声明 | 凭据持久化、曲库事实 |
| `DownloadStore` | GlobalID 作用域的下载/缓存状态与后台任务恢复映射 | 远程目录同步、播放状态 |

## 协调边界

`AuralisAppModel` 目前保留：

- App 级导航和展示协调；
- 将服务器连接结果交给目录同步器；
- 将播放、系统媒体、Agent 与页面动作接线；
- 对旧调用点提供只读兼容代理。

子 Store 是相应领域状态的唯一所有者。兼容代理不保存第二份状态，避免迁移过程中出现双真相源。子 Store 的变化暂时转发给 AppModel，以保证旧 View 不丢刷新；新代码应直接观察所需 Store，后续可逐页移除这层兼容传播。

## 大曲库与线程

`HomeStore` 对 2,000 首以上目录使用可取消的 utility detached 快照任务，并用 generation 丢弃过期结果。SwiftUI 主线程只接收最终投影，不在 `body` 内整库排序。

`DownloadStore` 用 `GlobalID(serverID + remoteID)` 保存下载状态。`DownloadManager` 的恢复快照同时携带 `serverID`，App 重启后不会依赖已经丢失的裸 `TrackID` 内存映射。

## 后续迁移规则

1. 新页面直接注入最小 Store，不向 AppModel 增加新的页面级 `@Published`。
2. 新领域逻辑进入对应 Store/Service；AppModel 只编排跨领域动作。
3. 在所有旧 View 完成迁移前保留兼容代理；不得建立并行持久化或复制数组。
4. 播放状态永远只通过 `PlaybackStore` 读写。
