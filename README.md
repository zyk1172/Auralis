# Auralis / 澜音

Auralis 是面向 iPhone、iPad 与 macOS 的原生私人音乐播放器。产品目标是连接
Navidrome/OpenSubsonic 服务器，提供可靠播放、离线资料库、专业桌面信息能力与可选的
隐私优先 AI 音乐策展。

当前版本：`0.1.0`，已接入真实 Navidrome/OpenSubsonic 服务器：资料库同步、流式播放、
按需歌词与封面均已走真实网络请求；当前限制见下文。

## 支持平台

- iOS/iPadOS 18+
- macOS 15+，原生 AppKit/SwiftUI 运行环境，不使用 Mac Catalyst
- Swift 6 严格并发检查

本机验证环境为 Xcode 27.0 beta、Swift 6.4、iOS/macOS 27 SDK。最低系统版本仍保持为
iOS 18 和 macOS 15。

## 产品截图

截图统一放在 [`Docs/Screenshots`](Docs/Screenshots)。截图必须来自成功构建后的本地
Simulator/App，且不使用第三方商业封面；本轮 iOS 27 Simulator 首次迁移失败，因此没有
提交伪造截图。

## 编译与运行

机器当前若激活的是 Command Line Tools，请显式选择完整 Xcode：

```bash
cd Auralis
xcodegen generate
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  open Auralis.xcodeproj
```

在 Xcode 中运行 `Auralis`（iPhone/iPad）或 `AuralisMac`（原生 macOS）。命令行验证：

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

`project.yml` 是工程定义的唯一维护入口；运行 `xcodegen generate` 可重建 Xcode 工程。

## 服务器歌词与封面

连接服务器后，歌词（`getLyricsBySongId`）与封面（`getCoverArt`）按需从服务器拉取并
在内存中缓存：切歌时自动加载当前曲目歌词，列表与播放页封面按显示尺寸请求、失败或
缺失时回退到应用内渐变占位组件。测试用的确定性曲库只存在于 TestSupport 目标，不再
出现在生产 UI。

## Navidrome / OpenSubsonic 配置

Phase 0 已提供 Endpoint Registry、Capability Registry、认证配置抽象和服务协议。真实登录、
同步和请求执行在 Phase 1 接入。服务器功能只根据 `getOpenSubsonicExtensions` 的响应启用，
不按服务器品牌猜测。凭据不得写入 `project.yml`、源码或 UserDefaults。

## OpenAI 兼容接口配置

Phase 0 已定义多 Provider 配置、`AIProvider`、SSE 解析、隐私权限和 Mock Provider。真实
`/v1/chat/completions` 网络请求、Keychain 存储、重试和取消在 Phase 5 接入。默认 API 路径：

```text
POST {baseURL}/v1/chat/completions
```

API Key 只允许进入 Keychain；日志不记录密钥、认证头、完整提示词或歌词。

## 架构

工程采用薄 App Target + 本地 Swift Package 多模块结构。详见
[`ARCHITECTURE.md`](ARCHITECTURE.md)。UI 不直接调用网络或数据库，播放器不接触
Navidrome 响应模型，AI 不能直接修改音频文件。

## 第三方依赖

Phase 0 运行时第三方依赖为零。GRDB、Nuke 与 AudioKit 只作为后续候选，尚未链接。
许可证与复用决策见 [`Docs/OpenSourceAudit.md`](Docs/OpenSourceAudit.md) 和
[`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md)。

## 隐私

未连接服务器时应用不向外部服务发送任何数据。AI 默认只发送用户允许的最少字段，并在请求前显示
Provider、模型、字段、Token 估算与歌词状态。详见 [`Docs/PrivacyModel.md`](Docs/PrivacyModel.md)。

## 当前限制（0.3.x 实际状态）

- 播放：AVFoundation 流式/本地播放、后台播放、锁屏/控制中心、AirPlay 已接入；Gapless / Crossfade / ReplayGain / 均衡器尚未实现（Phase 8 DSP 路线图）。
- 持久化：SQLite 本地目录、下载与离线文件、播放会话恢复已实现；「仅同步变化内容」的增量同步尚未落实（当前为全量重拉），全量同步的原子性与删除语义待完善。
- 安全：Keychain 凭据、真实 OpenAI 兼容 SSE 请求、设置备份导入导出已接入；备份加密使用 PBKDF2（600k 轮）。
- 主题：8 套内置主题可用；跟随系统 / 定时切换 / 封面取色尚未实现。
- 真机路由、后台任务、签名 Entitlement 与付费开发者账户能力未验证（需真机 + 真实服务器）。

## 文档索引

- [产品规格](Docs/ProductSpecification.md)
- [AI 架构](Docs/AIArchitecture.md)
- [元数据策略](Docs/MetadataStrategy.md)
- [主题系统](Docs/ThemeSystem.md)
- [隐私模型](Docs/PrivacyModel.md)
- [测试策略](Docs/TestingStrategy.md)
- [开源审计](Docs/OpenSourceAudit.md)
