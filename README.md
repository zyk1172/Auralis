# Auralis

> 面向 iPhone、iPad 与 macOS 的原生私人音乐播放器。连接你自己的
> Navidrome / OpenSubsonic 音乐服务器，把「可靠播放、离线资料库、隐私优先」放在第一位。

Auralis 是一款 SwiftUI 原生实现的私人音乐播放器，作为你自有音乐库（Navidrome 或任何
兼容 OpenSubsonic API 的服务器）的客户端，提供流畅的流式播放、离线下载、本地资料库、
专业播放控制与可选的隐私优先 AI 音乐助手。**没有账号体系、没有广告、不采集行为数据**，
音乐数据只属于你。

当前版本：`1.0.2`（以 `project.yml` 的 `MARKETING_VERSION` 为唯一事实来源）。

---

## ✨ 功能特性

### 播放与音质
- **流式播放**：Navidrome / OpenSubsonic 真实网络流，服务器原始质量
- **离线下载**：单曲 / 批量下载到本地，已缓存优先本地播放，断网可听
- **后台播放**：锁屏 / 控制中心持续播放，支持来电与耳机断开自动暂停、设备切换自动恢复
- **控制中心 / 锁屏 / 灵动岛**：歌曲信息、封面、进度、播放 / 暂停 / 上一首 / 下一首 / 拖动 / 随机 / 循环
- **播放控制**：0.5×–2.0× 变速、±30s / ±15s 跳转、单曲 / 列表循环、随机播放、睡眠定时
- **播完自动续播**：自然播完 / 流地址失效自动重试（≤2 次）并切下一首，进度实时落盘

### 资料库与同步
- **本地资料库**：SQLite + FTS5 全文检索，冷启动秒开，断网可浏览
- **多服务器隔离**：歌曲 / 收藏 / 播放次数 / 封面 / 歌词 / 离线音频均按「serverID:trackID」隔离，切换服务器不串库
- **播放会话恢复**：进程被系统终止后重启，自动恢复上次队列与进度（不自动出声）
- **完整浏览**：歌曲 / 专辑 / 艺术家 / 流派 / 歌单 / 收藏 / 最近播放 / 最常听 / 最近添加
- **搜索**：本地子串搜索（防抖）+ 服务器实时在线搜索
- **歌单管理**：创建 / 改名 / 删歌 / 重排 / 去重 / 合并 / 保存队列为歌单
- **收藏与评分**：歌曲 / 专辑 / 艺术家收藏实时同步服务器（star/unstar），评分、scrobble 播放计数

### 歌词与封面
- **结构化歌词**：按需拉取、磁盘缓存（含负缓存）、播放页滚动高亮
- **封面**：按显示尺寸请求、内存 + 磁盘 LRU 缓存、失败回退渐变占位

### AI 助手（可选，默认关闭）
- 自然语言操控：播放 / 搜索 / 歌单 / 收藏 / 下载 / 睡眠定时 / 诊断，40+ 真实工具
- **隐私优先**：三个权限开关（元数据 / 歌词 / 播放历史）真正生效，首次外发需用户确认
- 支持任意 OpenAI Chat Completions 兼容接口（OpenAI / DeepSeek / 通义 / Kimi / Ollama / LM Studio 等）
- **音乐下载（MoviePilot）**：点播本地与服务器都没有的歌曲、或直接说「下载某歌/某专辑」时，经 MoviePilot「音乐下载」插件跨站搜索并下载到 NAS 音乐目录（仅下载，不刮削/整理；中文专辑自动要求英文别名避免下错）

### 系统集成
- **Siri 与快捷指令**：播放指定歌曲 / 艺术家 / 专辑 / 收藏 / 随机 / 上一首 / 下一首 / 暂停等
- **Spotlight 索引**：歌曲 / 专辑 / 艺术家 / 歌单可被系统搜索
- **设置备份**：服务器账号 + AI 配置加密导出 / 恢复（AES-GCM + PBKDF2-HMAC-SHA256）
- **诊断**：播放 / 网络 / 缓存 / 错误诊断工具，全部脱敏

---

## 📱 支持平台

| 平台 | 最低版本 | 说明 |
|---|---|---|
| iOS / iPadOS | 26+（`project.yml` 为准） | iPhone 五标签；iPad 三栏 + 动态检查器 |
| macOS | 15+ | 原生 AppKit/SwiftUI，非 Catalyst |

- Swift 6 严格并发（`SWIFT_STRICT_CONCURRENCY=complete`），编译零警告（`SWIFT_TREAT_WARNINGS_AS_ERRORS=YES`）
- 本机验证环境：Xcode 27 beta / Swift 6.4 / iOS·macOS 27 SDK

---

## 🏗 架构

薄 App Target + 本地 Swift Package 多模块，单向依赖，核心不依赖 UI / 具体服务器 / AI 厂商。

```text
iOS App / macOS App
        ↓
      AppShell（页面、导航、AI 助手 UI）
        ↓
 Application（连接器、同步、策略、备份）
        ↓
  Domain 协议与稳定 ID
        ↓
 Infrastructure actors
OpenSubsonic · AVFoundation · SQLite · Keychain · AI Provider
```

主要模块：`AppShell` · `DesignSystem` · `ThemeEngine` · `Domain` · `OpenSubsonicKit` ·
`MusicLibrary` · `PlaybackEngine` · `PlaybackQueue` · `OfflineManager` · `ImagePipeline` ·
`LyricsKit` · `MetadataKit` · `AIKit` · `RecommendationEngine` · `Persistence` ·
`SecurityKit` · `Observability`

并发模型：UI 状态位于 `@MainActor`；队列 / 下载 / 数据库 / Provider / Repository 使用
actor 或 Sendable 值；音频实时线程不触碰数据库 / 网络 / SwiftUI。

---

## 🚀 快速开始

### 前置
- 完整版 Xcode（非仅 Command Line Tools），并已配置你的开发者团队
- 一台 Navidrome（或兼容 OpenSubsonic）服务器

### 构建与运行

```bash
cd Auralis
xcodegen generate
open Auralis.xcodeproj   # 选择 Auralis（iPhone/iPad）或 AuralisMac 运行
```

命令行验证（本机使用 Xcode beta 时需指定 DEVELOPER_DIR）：

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  swift test --package-path Packages/AuralisCore

DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  xcodebuild -project Auralis.xcodeproj -scheme Auralis \
  -destination 'platform=iOS Simulator,name=iPhone Air' CODE_SIGNING_ALLOWED=NO build

DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  xcodebuild -project Auralis.xcodeproj -scheme AuralisMac \
  -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO build
```

`project.yml` 是工程定义的唯一维护入口；`xcodegen generate` 可随时重建 Xcode 工程。

---

## 🔌 服务器配置

1. 打开「设置 → 服务器」→ 添加服务器
2. 填写：名称、地址（`http(s)://host:port`，公共地址强制 HTTPS）、用户名、密码或 API Key
3. App 自动探测服务器能力（`getOpenSubsonicExtensions`），只启用服务器真正支持的功能

- 支持 Navidrome（Subsonic API 1.16+ / OpenSubsonic）及其兼容实现
- 凭据只存 Keychain（`afterFirstUnlockThisDeviceOnly`），绝不写入工程、源码或 UserDefaults
- 支持多服务器添加 / 切换，数据按服务器完全隔离

---

## 🤖 AI 助手配置（可选）

1. 「设置 → AI 助手」启用并填写：Base URL、模型、API Key（存入 Keychain）
2. 三个隐私开关控制外发内容：**歌曲元数据 / 歌词 / 播放历史**
3. 首次向模型发送数据前，App 会弹出确认（允许一次 / 允许并记住 / 取消）

默认接口路径：`POST {baseURL}/v1/chat/completions`

---

## 🔒 安全与隐私

- **凭据**：服务器密码 / Token / AI API Key 全部只进系统 Keychain；`testConnection` 使用内存凭据，不落盘
- **默认拒绝**：不发送音频、完整路径、NAS 地址、用户名、服务器 Token、API Key、完整歌词与原始日志
- **日志脱敏**：崩溃日志与诊断在写入 / 读取时双重脱敏（认证参数、URL userinfo、Authorization 头），`recentErrors` 出口再次过滤
- **URL 策略**：拒绝内嵌凭据的地址；公共地址强制 HTTPS；仅允许本地 / 私有地址走 HTTP
- **备份加密**：设置备份 AES-GCM 加密，密钥由 PBKDF2-HMAC-SHA256（60 万轮）派生
- **删除**：可一键清空对话 / 缓存 / 全部 AI 数据；关闭 AI 后不发起任何网络请求，基础播放不受影响
- **数据隔离**：多服务器之间封面 / 歌词 / 离线音频 / 播放计数 / 收藏互不串库

详见 [`Docs/PrivacyModel.md`](Docs/PrivacyModel.md)。

---

## 📚 文档

| 文档 | 内容 |
|---|---|
| [产品规格](Docs/ProductSpecification.md) | 产品承诺与路线图（Phase 0–8） |
| [架构](ARCHITECTURE.md) | 模块职责、并发模型、数据身份 |
| [AI 架构](Docs/AIArchitecture.md) | AI Provider / 工具系统设计 |
| [元数据策略](Docs/MetadataStrategy.md) | 元数据合并 / 覆盖 / 撤销 |
| [主题系统](Docs/ThemeSystem.md) | Token 主题设计 |
| [隐私模型](Docs/PrivacyModel.md) | 默认拒绝、权限矩阵、密钥生命周期 |
| [测试策略](Docs/TestingStrategy.md) | 单元 / 集成 / UI / 性能分层 |
| [真机验收清单](Docs/真机验收清单.md) | 需真机 + 真实服务器验证的项 |
| [审计报告](Docs/全面审计报告-2026-08-08.md) | 全面审计结论与修复进度 |
| [开源审计](Docs/OpenSourceAudit.md) | 第三方依赖选型与许可 |

---

## 🗺 路线图（未实现 / 规划）

- 播放增强：Gapless 无缝、Crossfade、ReplayGain、均衡器（Phase 8 DSP）
- 同步增强：真正的增量同步（当前为全量重拉）、全量同步原子化与删除语义
- 平台扩展：CarPlay、桌面小组件、Apple Watch 遥控、Handoff、多用户
- 其它：真正增量同步、下载断点续传与 Wi-Fi 限制、多语言（当前仅中文）

---

## 📜 版本历史

详见 [`CHANGELOG.md`](CHANGELOG.md)。

- `0.3.4` — 控制中心 / 灵动岛 / Agent 工具系统；修复 iOS 构建
- `0.3.2` — 播放会话持久化、Siri 意图引擎、收藏 / 歌单服务器同步
- `0.3.0` — 播放页重构、离线下载、收藏同步、主题扩充
- `0.2.0` — 按需歌词 / 封面、恢复上次连接
- `0.1.0` — 首个可用版本：多模块架构、Demo 曲库、主题与测试
- `v1.0.0`（GitHub 标签）— 首个正式发布：完整播放链路 + 隐私 / 安全加固

---

## 📄 许可与致谢

- 本仓库为私有项目；第三方依赖与许可决策见 [`Docs/OpenSourceAudit.md`](Docs/OpenSourceAudit.md)
  与 [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md)
- 项目使用 Navidrome 的 OpenSubsonic API 规范进行互通
