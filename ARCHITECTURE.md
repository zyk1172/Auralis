# Architecture

## 目标

Auralis 的稳定核心不依赖 UI、具体服务器或 AI 厂商。Demo 与真实模式共享 Domain ID、用例
和界面，只替换协议实现。

```text
iOS App / macOS App
        ↓
      AppShell
        ↓
Application state and use cases
        ↓
Domain protocols and stable IDs
        ↓
Infrastructure actors
OpenSubsonic · AVFoundation · Persistence · Keychain · AI Provider
```

## 模块

| 模块 | 责任 | 允许依赖 |
|---|---|---|
| AppShell | 平台布局、导航、可访问 UI | Application/Domain-facing modules |
| DesignSystem | Token、通用组件、无业务状态 | SwiftUI |
| ThemeEngine | 主题定义、选择与持久偏好 | DesignSystem |
| Domain | 稳定 ID、实体、协议、Demo 数据 | Foundation |
| OpenSubsonicKit | Endpoint、能力、认证与 DTO 边界 | Domain, SecurityKit |
| MusicLibrary | 分页资料库用例与 Demo repository | Domain |
| PlaybackEngine | 播放状态机与未来 AVFoundation 适配 | Domain, Queue, Observability |
| PlaybackQueue | actor 隔离的队列状态 | Domain |
| OfflineManager | 下载状态与缓存淘汰 | Domain |
| ImagePipeline | 封面请求与缓存协议 | Domain |
| LyricsKit | 静态/同步歌词仓库与时间线 | Domain |
| MetadataKit | Overlay、候选、合并、撤销 | Domain |
| AIKit | Provider、隐私配置、SSE | Domain, SecurityKit |
| RecommendationEngine | 确定过滤、排序、多样性、ID 校验 | Domain |
| Persistence | 迁移计划与多账户隔离边界 | Domain |
| SecurityKit | 凭据标识、Vault 协议和脱敏 | Foundation |
| Observability | OSLog 分类与性能测量入口 | OSLog |
| TestSupport | 确定性 fixture | Domain |

## 并发

- 工程以 Swift 6、`SWIFT_STRICT_CONCURRENCY=complete` 构建。
- UI 状态位于 `@MainActor`。
- 队列、下载、数据库、Provider 和 repository 使用 actor 或 Sendable value。
- 音频实时线程不得做数据库、网络、日志格式化或 SwiftUI 工作。

## 平台边界

`Auralis` 是 iOS/iPadOS Target；`AuralisMac` 是原生 macOS Target。共享模块不使用 Catalyst
假设。iPhone 为 TabView，iPad 与 Mac 为三栏 NavigationSplitView；Phase 4 继续加入 Mac
Table、多选、窗口和拖放。

## 依赖注入

Phase 0 由 `AuralisAppModel` 注入 Demo Catalog 和 Demo Playback Engine。后续改为 App
Composition Root 注入协议存在类型，UI 不会创建 URLSession、数据库或服务器 DTO。

## 数据身份

所有服务器对象的 ID 都由 `serverID + stable server object ID` 构成持久域身份。离线下载只
附着到同一 Track ID，不产生“离线 Track”。当前 Demo 以 `demo-track-*` 模拟该约束。
