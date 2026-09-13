# Semantic Collision Recommendation

Auralis 的开放语义推荐采用 **Open-world LLM Recall -> Closed-world Catalog Grounding**。

## 为什么增加这一层

原有 Recommendation Index、`recommend_by_mood`、`recommend_by_constraints` 都是可靠的本地召回，但自由自然语言最终需要压缩到有限标签或字段。对于“凌晨独自开车、有城市霓虹感但不要太丧”这类开放语义，云端模型更适合先在音乐知识中产生候选；Auralis 再负责证明这些候选是否真实存在于用户当前音乐库。

## 分层策略

1. **开放语义推荐（第一梯队）**
   - Agent 理解用户需求和目标数量 N；
   - 生成约 `3N-5N` 个候选（最多 200），优先给出 `title + artist`，可带 `album`；
   - 一次调用 `recommendation_ground_candidates` 批量撞库；
   - Runtime 只返回真实 GlobalTrackID，并在本地执行“不喜欢”、去重、同艺人上限和歧义拒绝；
   - 命中不足时进入第二/第三梯队补足。
2. **Recommendation Index（第二梯队）**
   - 适合固定 mood / scene / style / texture 等 taxonomy，或模型候选对冷门本地库命中率低时。
3. **原有本地推荐（第三梯队）**
   - `recommend_by_mood` / `recommend_by_constraints` / `library_select_tracks` / smart queue。
4. **确定性筛选例外**
   - “2010-2020、FLAC、只要收藏、只要离线、排除某艺人”等条件直接查询本地；不绕云端候选生成。

## Grounding 契约

模型输入：

```json
{
  "candidates": [
    {"title": "Something", "artist": "The Beatles", "album": "Abbey Road"}
  ],
  "targetCount": 20,
  "maxPerArtist": 2
}
```

Runtime 输出只包含本地真实歌曲。模型候选本身不是事实，未命中的歌不得展示、播放、建歌单或生成虚假 TrackID。

### 匹配层级

- Unicode / 大小写 / 全半角 / 标点 / 空白规范化；
- 标题 + 艺人精确匹配优先；
- 对 Remaster/重制后缀做保守版本归一；
- 只有艺人强匹配时才允许高阈值标题模糊匹配；
- 没有艺人信息时只接受唯一标题精确匹配；同名歧义拒绝猜测；
- album 只作为同名版本加分，不把 album 缺失当失败；
- Runtime 最终排除 disliked、GlobalID 重复，并执行 `maxPerArtist`。

## 跨客户端

- **Apple (iOS/macOS)**：canonical descriptor 在 `AgentToolRegistry`，执行器为 `SemanticCollisionRecommendation`；Tool Broker、Task Working Set、Capability Catalog、Composition Examples 同步声明第一梯队语义。
- **Android 手机 / Android TV**：两端共用 `feature:assistant` 的 `AssistantToolHost` 和 `SemanticCollisionMatcher`，因此使用同名、同参数、同降级语义，不在 TV 另造一套实现。

## 失败与降级

`matchedCount < targetCount` 时工具返回 `fallbackNeeded=true`。Agent 应使用 Recommendation Index 或原有本地推荐补足，不能随机把未 grounding 的模型候选塞进结果。Provider 不可用时直接使用原有本地链路。

## 性能

该工具是**单次批量调用**，禁止让模型逐首调用 `library_search`。当前实现一次构建规范化本地索引并处理最多 200 个模型候选；这已经消除了几十次模型/工具往返。后续如果超大曲库基准显示字符串比较成为瓶颈，可把规范化 `(artist,title)` key 持久化/缓存成哈希索引，而不改变 Agent 协议。

## 回归测试

Apple 与 Android 均覆盖：

- Remaster/重制规范化命中；
- 同名错误艺人拒绝；
- 缺艺人同名歧义拒绝；
- disliked 排除；
- 重复候选去重；
- 同艺人上限；
- Tool Broker 仍保留旧 `recommend_by_mood` 作为降级。
