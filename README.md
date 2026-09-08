# Auralis

Auralis 是一套面向个人音乐库的原生音乐播放器，连接 Navidrome 或其他兼容
OpenSubsonic API 的服务器。项目将完整源码公开，重点是可靠播放、离线资料库、隐私优先的
可选 AI Assistant，以及不影响音频链路的 Music Haptics。

Auralis 不提供官方音乐内容或音乐服务器。使用者需要自行管理有权访问和播放的音乐库、
服务器以及第三方服务凭据。

## Features

- Music playback：流式播放、离线下载、后台播放、锁屏/控制中心控制、队列、随机/循环、
  倍速、跳转和播放会话恢复。
- Music library：本地缓存、SQLite/FTS5 搜索、专辑/艺术家/流派/歌曲浏览、收藏、评分、
  scrobble、歌词/封面缓存，以及多服务器数据隔离。
- Playlist：浏览、创建、重命名、编辑、排序、去重、合并，并将当前队列保存为服务器歌单。
- Search：本地资料库搜索和 OpenSubsonic 服务器搜索。
- AI Assistant：通过可配置的模型 Provider 进行自然语言搜索、播放、资料库操作、队列和
  歌单工作流；工具注册、发现、动态加载、上下文恢复和多步骤任务属于完整源码的一部分。
- Music Haptics：对播放内容进行可选的触觉分析和同步。触觉分析失败、延迟或不支持时，
  不应暂停播放、阻塞音频线程、破坏 AudioSession 或造成音频卡顿。
- Apple integration：AVFoundation、MediaPlayer、App Intents、后台音频和系统媒体控制。
  项目不包含 Apple Music 私有内容或 MusicKit 服务依赖。

## Platforms

| 平台 | 当前工程要求 | 状态 |
| --- | --- | --- |
| iOS / iPadOS | 26.0 或更高 | Apple 主实现；iPhone 与 iPad 共用 SwiftUI 应用 Shell |
| macOS | 15.0 或更高 | Apple 主实现；原生 SwiftUI/AppKit，不是 Catalyst |
| Android | minSdk 26、targetSdk 34；JDK 17 | `android/` 下的独立实现，功能持续对齐中 |

Apple 工程使用 Swift 6 严格并发。`project.yml`、`Packages/AuralisCore/Package.swift` 和
`android/gradle/libs.versions.toml` 是版本与构建约束的主要事实来源。Music Haptics 是
Apple 平台能力；Android 实现不应被理解为提供同一套 Apple 触觉 API。

## Requirements

- Apple 构建：Xcode 27.0、Swift 6，以及与工程要求匹配的 iOS/macOS SDK。
- XcodeGen 2.46.0，用于从 `project.yml` 生成 `Auralis.xcodeproj`。
- Android 构建：JDK 17；使用仓库内的 Gradle Wrapper，不需要全局安装 Gradle。
- 一个可访问的 Navidrome/OpenSubsonic 服务器，以及你有权使用的音乐内容。

工程不提交开发者 Team ID。需要签名的本地运行由开发者在 Xcode 中选择自己的团队；无签名
构建和 CI 使用 `CODE_SIGNING_ALLOWED=NO`。

## Build

从一个干净的工作区开始：

```bash
git clone https://github.com/zyk1172/Auralis.git
cd Auralis

# Apple 工程
xcodegen generate
open Auralis.xcodeproj

# SwiftPM 单元测试
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  swift test --jobs 1 --package-path Packages/AuralisCore

# 不签名的 macOS 与 iOS 通用构建
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  xcodebuild -project Auralis.xcodeproj -scheme AuralisMac \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build

DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  xcodebuild -project Auralis.xcodeproj -scheme Auralis \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build

# Android 单元测试与 Debug 构建
cd android
./gradlew testDebugUnitTest :app-mobile:assembleDebug :app-tv:assembleDebug
```

如果需要运行 UI smoke test，请使用已经创建的 iPhone Simulator 或连接的设备，并按
`Docs/ManualValidation.md` 执行；项目不会要求贡献者创建新的模拟器。CI 使用 runner 上已有
的可用设备并在测试后由 runner 回收状态。

## AI Assistant

AI Assistant 默认可以保持未配置。没有 API key 或没有启用 Provider 时，基础播放、资料库、
本地搜索和不需要外部模型的功能仍可使用；不会因为缺少模型凭据而阻塞播放器。

当前代码包含 OpenAI-compatible Provider（Chat Completions 与 Responses API）和 Anthropic
Messages Provider。用户在设置中提供 endpoint、模型、协议和 API key，凭据存入系统
Keychain；请求前的隐私同意控制元数据、歌词和播放历史是否可以外发。模型调用、网络请求、
工具调用和 Provider 能力由现有运行时决定，不由本 README 限制次数或结果数量。

`Config/Secrets.example.xcconfig` 只提供空值名称，供需要本地 xcconfig 工作流的开发者参考：

```text
OPENAI_API_KEY =
GEMINI_API_KEY =
ANTHROPIC_API_KEY =
```

不要把真实值写入仓库、Issue、PR、日志或 README。正常 App 配置应优先通过设置界面进入
Keychain；本地 `Config/Secrets.xcconfig` 被 `.gitignore` 忽略，且不应包含真实凭据之外的
项目专属配置。

## Haptics and playback priority

Music Haptics 是播放的可选旁路能力。播放引擎、队列、seek、后台恢复和 track transition
是主路径；触觉初始化、分析、同步或硬件不支持都必须在隔离边界内失败。遇到问题时应先保住
音频播放和 AudioSession，再记录可诊断的 haptics 状态。

## Contributing

请先阅读 [`CONTRIBUTING.md`](CONTRIBUTING.md)。贡献应通过 fork、独立分支、可复现测试和
可审查的 pull request 提交。不要提交 API key、用户数据、未经授权的音乐/图片/字体、私有
签名材料或许可证不兼容的复制代码。

## License

Auralis source code is licensed under **GPL-3.0-only**. See [`LICENSE`](LICENSE) for the full
license terms. 发生 GPL 所规定的分发情形时，基于 GPL 覆盖代码的衍生作品需要遵守 GPL 的
对应源码与再分发要求；具体边界以许可证正文为准，不以本 README 扩张法律结论。

第三方依赖和平台 SDK 仍受其各自许可证、条款和分发条件约束，详见
[`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md)。

## Brand

源码许可证不自动授予 Auralis 官方名称、Logo、App Icon、官方视觉资产或官方发布身份。
Fork 可以依法修改和重新分发 GPL 源码，但发行版应使用自己的名称和视觉资产，并避免让用户
误认为其是官方 Auralis 版本。详见 [`TRADEMARKS.md`](TRADEMARKS.md)。

## Documentation

- [架构](ARCHITECTURE.md)
- [AI 架构](Docs/AIArchitecture.md)
- [隐私模型](Docs/PrivacyModel.md)
- [测试策略](Docs/TestingStrategy.md)
- [手工验收](Docs/ManualValidation.md)
- [开源审计](Docs/OpenSourceAudit.md)
- [安全政策](SECURITY.md)

## Project status

本次治理目标是 open-source readiness，不自动发布 GitHub Release，不自动合并 pull request，
也不改变仓库可见性。正式版本号、设备验收和真实服务集成应在独立的发布审查中确认。
