# Open Source Audit

审计日期：2026-08-04。只使用项目官方文档或官方仓库；没有从 GPL 项目复制代码。

| 项目/规范 | 用途 | 许可证/数据权利 | 直接依赖 | 复制代码 | 决策理由 |
|---|---|---|---|---|---|
| [OpenSubsonic](https://github.com/opensubsonic/open-subsonic-api) | API/扩展规范 | Apache-2.0 | 否，规范互操作 | 否 | Capability Registry 以官方扩展名为准；客户端自行实现 |
| [Navidrome](https://github.com/navidrome/navidrome) | 目标服务器、兼容性研究 | GPL-3.0 | 否 | 否 | 仅做黑盒互操作与产品边界研究 |
| [Amperfy](https://github.com/BLeeEZ/amperfy) | Apple 平台功能边界研究 | GPL-3.0 | 否 | 否 | 不链接、不复制；除非未来整体许可证决策改变 |
| [AudioKit](https://github.com/AudioKit/AudioKit) | EQ、频谱、DSP 候选 | MIT；v5.7.2（2026-03-31） | Phase 0 否 | 否 | AVFoundation 先满足播放；Phase 8 再按必要性引入 |
| [GRDB.swift](https://github.com/groue/GRDB.swift) | SQLite、迁移、观察候选 | MIT；7.8.0（2025-10-02） | Phase 0 否 | 否 | 维护活跃且适合 10 万曲库；Phase 1 前做 schema spike |
| [Nuke](https://github.com/kean/Nuke) | 封面加载、降采样、缓存候选 | MIT；13.x 支持 Swift 6.2/Xcode 26 | Phase 0 否 | 否 | 能减少可靠图像管线重复工作；Phase 1 决策 |
| [MusicBrainz API](https://musicbrainz.org/doc/MusicBrainz_API) | 元数据搜索与候选 | 核心数据 CC0；补充数据 CC BY-NC-SA 3.0；Server GPLv2+ | API，Phase 6 | 否 | 必须识别 User-Agent、平均不超过 1 req/s，并保留字段来源 |
| [Cover Art Archive](https://coverartarchive.org/) | 按 release MBID 获取封面 | 图片版权归各权利人 | API，Phase 6 | 否 | 不把远端图片当作自由资产；缓存和分发策略需单独评估 |
| Foundation/AVFoundation/MediaPlayer | 播放、网络和系统控制 | Apple SDK | 是 | 不适用 | 原生平台主路径 |
| XcodeGen | 可维护地生成 Xcode 工程 | MIT | 仅开发工具 | 否 | `project.yml` 比手工 pbxproj 更易审查和重建 |

## 主动比较结论

- Swift 开源播放器中 Amperfy 功能完整，但 GPL-3.0 不适合直接复用代码；其队列、离线、
  ReplayGain 和平台边界仅作为研究清单。
- AVFoundation 足以先完成 HTTP/local、系统路由和 Remote Command；Gapless/Crossfade 需以
  真实格式和服务器转码行为做专门实验，不能只靠播放器 UI 状态推断。
- OpenAI Compatible 网络层仅为一个 Provider adapter，自行使用 URLSession/SSE 可以避免
  为小接口引入绑定单一厂商的大型 SDK。

## 引入门禁

任何新包必须记录固定版本、上游 URL、许可证全文、修改、二进制来源、平台需求、安全公告
与移除方案，并同步 `THIRD_PARTY_NOTICES.md`。GPL/LGPL/MPL/AGPL 需产品和法律单独批准。
