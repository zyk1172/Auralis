# Auralis

Auralis 是一套面向个人音乐库的跨平台原生音乐播放器。它既可以连接 Navidrome 或其他兼容
OpenSubsonic API 的服务器，也可以完全不配置服务器，只使用设备上的本地音乐文件。

当前项目同时维护 Apple 与 Android 实现，重点包括：可靠播放、统一的本地/服务器资料库、
离线下载、自然语言 AI Assistant、Android TV 十英尺界面，以及 Apple 平台上的 Music Haptics。
Auralis 不提供官方音乐内容或音乐服务器；使用者需要自行管理有权访问和播放的音乐内容，
以及可选的第三方模型服务凭据。

## Features

- Music playback：流式播放、本地文件播放、离线下载、后台播放、锁屏/控制中心控制、队列、
  随机/循环、seek、倍速和播放会话恢复。
- Local music：本地音乐是一等数据源，不再伪装成 OpenSubsonic 服务器。Apple 使用本地文件
  URL / security-scoped access，Android 使用 SAF；没有活动服务器时，Library/Search 仍可作为
  纯本地播放器使用。
- Unified catalog：有活动服务器时，用户可见的 Library/Search/Agent 会组合“当前服务器 +
  本地音乐”；其他已保存服务器仍保持隔离，服务器写操作也不会错误落到本地来源。
- Downloads：服务器下载完成后会获得稳定的本地 canonical 身份，同时保留原远端 Global ID
  作为兼容别名；iOS/iPadOS 还会把同一份音频整理到 Files 可见的 `LocalMusic` 标准单曲文件夹，
  不额外复制一份音频。
- Music library：SQLite/FTS5、Room、本地缓存、专辑/艺术家/流派/歌曲浏览、收藏、评分、
  scrobble、歌词/封面缓存，以及多服务器隔离。
- Playlist：浏览、创建、重命名、编辑、排序、去重、合并，并支持把当前队列保存为歌单。
- AI Assistant：通过可配置模型 Provider 执行自然语言搜索、播放、队列、资料库和歌单工作流；
  支持工具发现/动态加载、上下文恢复和多步骤任务。开放语义推荐采用“模型召回 → 本地真实曲库
  grounding → 本地确定性过滤/回退”，不会把曲库中不存在的 LLM 幻觉歌曲直接交给播放器。
- Music Haptics：Apple 平台优先使用系统能力；自定义 fallback 使用独立的触觉分析链路，包含
  onset 定位、band-aware 置信度、节拍/瞬态塑形和 Core Haptics materialization。触觉失败不得阻塞
  音频主链路。
- Apple UI：iPhone/iPad 共用 SwiftUI App Shell；iPad Now Playing 会根据实际窗口尺寸自适应，
  macOS 为原生 SwiftUI/AppKit 实现，不使用 Catalyst。
- Android / TV：Android Mobile 与 Android TV 共享核心播放、资料库和 Assistant 能力；TV 使用
  独立的 D-pad / 焦点导航、左侧十英尺导航和全屏 Now Playing，而不是把手机 UI 直接放大。

## Local music

### iPhone / iPad

Auralis 会在启动时自动建立一个 Files 可见的本地音乐目录：

```text
文件 → 我的 iPhone / 我的 iPad → Auralis → LocalMusic
```

不需要先在“文件”App 中手动创建或选择根目录。`LocalMusic` 采用**一首歌一个文件夹**的组织方式，
每个普通本地歌曲一级子文件夹代表一首歌曲：

```text
LocalMusic/
├── README.txt
├── 歌曲 A/
│   ├── audio.flac
│   ├── cover.jpg
│   ├── lyrics.lrc
│   └── metadata.json
└── 歌曲 B/
    ├── audio.m4a
    ├── cover.png
    ├── lyrics.txt
    └── metadata.json
```

每个本地歌曲文件夹必须恰好包含 1 个受支持音频文件。封面、歌词和 `metadata.json` 是一等 sidecar：
Auralis 会直接读取本地封面、LRC/TXT 歌词和元数据覆盖信息，并把它们接入现有封面缓存、歌词时间轴
和统一资料库。封面或歌词缺失不会阻止纯音乐或无封面歌曲播放。

“设置 → 本地音乐 → 导入歌曲”可以直接选择音频文件，也可以选择已经整理好的一首歌文件夹。
Auralis 会识别音频内嵌标题/艺人/专辑/流派/封面，以及同目录的封面、LRC/TXT 歌词和
`metadata.json`，然后复制整理成上面的标准 package；直接选择多个散落音频时只匹配同名 sidecar，
避免错误复用同一个 `cover.jpg` 或 `lyrics.lrc`。

当前音频支持 MP3、M4A、AAC、ALAC、FLAC、WAV、AIFF、OGG 和 Opus；封面支持
JPG/JPEG、PNG、WebP、HEIC/HEIF；歌词支持 LRC 和 TXT。应用会在 `LocalMusic/README.txt`
自动写入目录示例和规则。完整规范见 [`Docs/LocalMusicFolderFormat.md`](Docs/LocalMusicFolderFormat.md)。

从服务器音乐库下载歌曲时，Auralis 会先完成可靠的后台下载，再把**同一份音频移动**进
`LocalMusic` 的标准单曲文件夹，并在服务器可提供时写入封面、LRC/TXT 歌词和 `metadata.json`。
这些文件夹在 Files 中可见，但仍由下载管理器拥有，并带内部所有权标记，因此本地扫描不会把它们
再次作为第二首本地歌曲导入。旧版本内部缓存会在能够重新取得服务器元数据时逐步迁移；离线时仍保留
原缓存可播放。删除这类文件建议使用 App 内“删除下载”，以同步清理下载索引和整个歌曲文件夹。

### macOS

macOS 继续使用用户显式选择的 security-scoped 文件夹来源，授权会持久化，并在启动时恢复、
重新扫描并发布到统一资料库。历史外部目录保持递归音频扫描兼容；同目录的封面、歌词和
`metadata.json` sidecar 也可以被读取。服务器下载仍由 Auralis 管理，不使用 iOS 的 Files 可见根目录。

### Android / Android TV

Android 使用持久化 SAF tree URI 管理本地文件夹；Mobile 与 TV 共享本地音乐运行时与统一资料库。
无活动 OpenSubsonic 服务器时仍可进入本地 Library/Search/Assistant 读路径。本次 iOS/iPadOS
Files 可见下载 package 与“导入歌曲”改动不改变 Android 的 SAF 存储行为。

## Platforms

| 平台 | 当前工程要求 | 状态 |
| --- | --- | --- |
| iOS / iPadOS | iOS 26.0+ | Swift 6 / SwiftUI；本地音乐、服务器资料库、Assistant、Music Haptics |
| macOS | macOS 15.0+ | 原生 SwiftUI/AppKit；不是 Catalyst |
| Android Mobile | minSdk 26、compile/targetSdk 36；JDK 17 | Compose + Media3；本地/服务器统一资料库 |
| Android TV | minSdk 26、compile/targetSdk 34；JDK 17 | 独立 TV Shell、D-pad/焦点导航、全屏播放器 |

Apple 工程使用 Swift 6 严格并发。Android 当前使用 AGP 8.12.2；版本与构建约束以
`project.yml`、`Packages/AuralisCore/Package.swift`、`android/gradle/libs.versions.toml` 和各
App module 的 `build.gradle.kts` 为准。

## Requirements

- Apple 构建：Xcode 27.0、Swift 6，以及与工程要求匹配的 iOS/macOS SDK。
- XcodeGen 2.46.0，用于从 `project.yml` 生成 `Auralis.xcodeproj`。
- Android 构建：JDK 17；使用仓库内的 Gradle Wrapper，不要求全局安装 Gradle。
- 本地模式不要求服务器。
- 如果需要服务器同步、远程播放、服务器歌单或 scrobble，需要一个可访问的
  Navidrome/OpenSubsonic 服务器和你有权使用的音乐内容。
- AI Assistant 可保持未配置；需要云模型时再提供相应 Provider 的 endpoint / model / API key。

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

如果需要运行 UI smoke test，请使用已经创建的 iPhone Simulator、Android Emulator 或连接设备，
并按 `Docs/ManualValidation.md` 执行。CI 不依赖贡献者临时创建新的测试设备。

## AI Assistant

AI Assistant 默认可以保持未配置。没有 API key 或没有启用 Provider 时，播放、资料库、本地搜索、
下载和其他不依赖外部模型的功能仍可正常使用。

当前代码包含 OpenAI-compatible Provider（Chat Completions 与 Responses API）和 Anthropic
Messages Provider。用户在设置中提供 endpoint、模型、协议和 API key，凭据存入系统安全存储；
请求前的隐私同意控制元数据、歌词和播放历史是否可以外发。

开放语义推荐会先让模型生成候选，再把候选批量 grounding 到当前真实可播放目录中；错误艺术家、
同名歧义、已 dislike 曲目、重复结果和曲库中不存在的候选会在本地被过滤。确定性的年份、无损、
离线、收藏、排除艺术家/流派等约束仍优先使用本地查询，不会为了“像 AI”而强制绕一遍模型。

`Config/Secrets.example.xcconfig` 只提供空值名称：

```text
OPENAI_API_KEY =
GEMINI_API_KEY =
ANTHROPIC_API_KEY =
```

不要把真实值写入仓库、Issue、PR、日志或 README。正常 App 配置应优先通过设置界面进入安全存储；
本地 `Config/Secrets.xcconfig` 被 `.gitignore` 忽略。

## Haptics and playback priority

Music Haptics 是播放的可选旁路能力。播放引擎、队列、seek、后台恢复和 track transition 是主路径；
触觉初始化、分析、同步或硬件不支持都必须在隔离边界内失败。系统 Music Haptics timeline 可用时优先
使用系统路径；自定义分析只作为 fallback，不宣称复现 Apple 的私有生成算法。

## Release / CI

Apple 与 Android CI 已分流，平台无关修改按各自路径触发对应检查。当前测试发布 workflow 在推送
版本 tag 后生成 GitHub pre-release，发布 Android Mobile / TV Debug APK，以及不签名的 macOS DMG。
Android APK 使用 Debug key 签名以满足 Android 安装要求；当前 release flow 不生成需要付费开发者签名
材料的 iOS/iPadOS IPA。

## Contributing

请先阅读 [`CONTRIBUTING.md`](CONTRIBUTING.md)。贡献应通过 fork、独立分支、可复现测试和可审查的
pull request 提交。不要提交 API key、用户数据、未经授权的音乐/图片/字体、私有签名材料或许可证
不兼容的复制代码。

## License

Auralis source code is licensed under **GPL-3.0-only**. See [`LICENSE`](LICENSE) for the full
license terms. 发生 GPL 所规定的分发情形时，基于 GPL 覆盖代码的衍生作品需要遵守 GPL 的对应源码
与再分发要求；具体边界以许可证正文为准，不以本 README 扩张法律结论。

第三方依赖和平台 SDK 仍受其各自许可证、条款和分发条件约束，详见
[`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md)。

## Brand

源码许可证不自动授予 Auralis 官方名称、Logo、App Icon、官方视觉资产或官方发布身份。Fork 可以
依法修改和重新分发 GPL 源码，但发行版应使用自己的名称和视觉资产，并避免让用户误认为其是官方
Auralis 版本。详见 [`TRADEMARKS.md`](TRADEMARKS.md)。

## Documentation

- [架构](ARCHITECTURE.md)
- [AI 架构](Docs/AIArchitecture.md)
- [本地音乐文件夹格式](Docs/LocalMusicFolderFormat.md)
- [本地音乐统一资料库](Docs/LocalMusicUnifiedCatalog.md)
- [本地下载身份](Docs/LocalMusicDownloadIdentity.md)
- [语义碰撞推荐](Docs/SemanticCollisionRecommendation.md)
- [隐私模型](Docs/PrivacyModel.md)
- [测试策略](Docs/TestingStrategy.md)
- [手工验收](Docs/ManualValidation.md)
- [跨平台发布](Docs/Release.md)
- [开源审计](Docs/OpenSourceAudit.md)
- [安全政策](SECURITY.md)

## Project status

Auralis 仍处于持续开发阶段，但本地音乐、OpenSubsonic、Apple/Android playback、Android TV、
Assistant、推荐 grounding、离线身份迁移和平台 CI 已进入同一主线，而不再是彼此独立的实验分支。
正式版本号、真实设备验收、签名发行和具体服务器兼容性仍需要在每次 release 前单独确认。
