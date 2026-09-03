# Testing Strategy

## Phase 0 自动化

Swift Testing targets 覆盖：Demo 数据与稳定 ID、Capability Registry、Endpoint URL、队列
移动/删除、Metadata Overlay 合并/撤销、SSE 分块、Mock Provider、推荐过滤/多样性/ID 校验、
缓存淘汰。

运行：

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  swift test --package-path Packages/AuralisCore
```

## 后续层级

- 单元：请求签名/响应解析、状态机、迁移、下载和 JSON Schema；
- 集成：Mock OpenSubsonic/OpenAI Server、断线、取消、续传、队列恢复、多账户；
- UI：首次启动、添加服务器、播放、歌词、主题、推荐、元数据、iPad 分栏和 Mac 键盘；
- Snapshot/Preview：小/大 iPhone、iPad 竖横、Mac 小/大、深浅、超大字体、Reduce Transparency；
- 性能：10 万曲分页、搜索、封面解码、数据库查询、SSE 和频谱帧预算。

模拟器构建不等于后台音频、蓝牙/AirPlay、耳机断开或系统终止恢复的真机验证，这些结果必须
在测试矩阵中单独标注。

## Music Haptics 后台/锁屏验收门槛

Music Haptics 的调度状态和身份迁移可以由 Swift Testing 覆盖，但模拟器不能证明 Taptic
Engine 在真实系统生命周期中的持续输出。涉及后台播放的 PR 必须在真实 iPhone 上记录
设备型号、iOS 构建号、App 构建号和诊断页快照，并逐项完成以下门槛：

| 场景 | 必须确认的结果 |
| --- | --- |
| 前台播放 → Home → 后台连续 5 分钟 | AVPlayer 继续播放；若 Core Haptics 未报告 `.applicationSuspended`，调度器、分析器和震动输出不因 Scene background 自动停止 |
| 前台播放 → 锁屏 3 分钟 → 解锁 | 锁屏期间不出现无依据的 haptics suspension；解锁后以 AVPlayer 位置重建未来窗口，不能从过期 UI 位置继续 |
| 系统报告 `.applicationSuspended` | 诊断显示 `applicationSuspended=true` / `hapticsSuspended=true`，调度器和分析器暂停并保存 checkpoint |
| 控制中心暂停、恢复、拖动进度、变速 | 播放状态和 haptics 时钟跟随 AVPlayer；后台不接受 UI 估算 tick 覆盖权威位置 |
| 后台切歌与 prepared-next | 音频不断播；下一首的分析不会把 Scene background 当作禁止条件，也不会创建新的后台 Core Haptics 引擎 |
| 后台缓冲、恢复、AirPods 控制 | 缓冲时停止未来输出，恢复时从新的 AVPlayer 位置 rebase；不误判为系统 suspension |

自动测试通过不等于上述真机门槛通过；在没有真机记录前，PR 必须明确标注后台触觉
E2E 未验证。
