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
