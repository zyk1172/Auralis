# Product Specification

## 产品承诺

Auralis 是私人音乐库的原生 Apple 客户端：可靠播放优先，AI 是可关闭的增强层。产品不能
为了炫酷牺牲队列、离线、可访问性或音频线程稳定性，也不能把服务器不支持的能力做成虚假入口。

## Phase 0 可用范围

- iPhone 五标签信息架构与完整播放页；
- iPad/Mac 三栏结构和动态检查器；
- 8 套 Token 主题；
- 无账号、无密钥可运行的 200 首 Demo 曲库；
- 队列、歌词、音质、元数据和 AI 策展的交互骨架；
- 对无歌词、无搜索结果和未分类状态的可操作说明；
- Swift Package 模块与自动测试。

## 非功能需求

- 10 万曲目必须分页查询，首屏禁止全库装载；
- 封面异步降采样，缓存有容量与 LRU 约束；
- 搜索去抖，SSE 和 AI 请求可取消；
- Reduce Motion/Transparency、Dynamic Type、VoiceOver；
- 低电量/后台停止视觉刷新；
- 无凭据、私人地址和完整提示词日志。

## 路线图

Phase 1 OpenSubsonic；Phase 2 AVFoundation 播放；Phase 3 下载和歌词；Phase 4 专业平台
交互；Phase 5 AI Provider/Keychain；Phase 6 元数据；Phase 7 对话推荐；Phase 8 DSP 和功耗。

每阶段都必须先通过 package tests 与 iOS/iPadOS/macOS builds，真实服务器、真机路由和
Entitlement 结果单独记录，不能由 Mock 推断。
