# Auralis Fixed Recommendation Taxonomy v3

Auralis 的 Recommendation Index 是 **固定 taxonomy 分类索引**。AI 只负责从
`RecommendationIndexTaxonomy` 已定义的标签中选择；AI 永远不能创建新标签。

旧架构 `Fixed Taxonomy + AI Semantic Tags` 已废弃。`semanticTags`,
`semanticTagsOnly`, `tag_vocabulary`, `dimension = "tag"` 不再进入正式分类链路。

## Taxonomy 职责

- `mood`：音乐自身带来的情绪 / 心理感受。
- `scene`：现实生活场景、时间、活动、环境。
- `theme`：用户为什么现在想听（情境 / 人生主题）。
- `genre`：大类音乐类型。
- `style`：更细的流派 / 子流派 / 风格。
- `vocal`：人声存在形式、声部和演唱方式。
- `instrument`：主要可感知乐器 / 编制。
- `texture`：声音质感、制作质感、空间感、编配密度。
- `rhythm`：节奏 / 律动结构。

边界：

- Mood ≠ Scene ≠ Theme。
- Genre ≠ Style。
- Instrument ≠ Texture。

## 唯一 Source of Truth

- `RecommendationIndexTaxonomy` 是唯一 taxonomy 数据源。
- 每个标签有稳定 `TagID`（如 `mood.sacred`）、`displayName` 和可选 aliases。
- JSON Schema enum、LocalCatalog 写入校验、UI displayName、Agent taxonomy
  search 全部从同一份数据生成。

## AI 分类协议 v4

分类模型只返回内容，不拥有批次身份。最小 wire contract 是：

```json
{"items":[{"id":"server:track","tags":["genre.pop"],"features":{"energy":6},"confidence":0.8}]}
```

`items` 与每个 item 的 `id` 必须存在；`tags`、`features`、`confidence` 都可省略。
模型不再返回 `batchID`、`revision` 或九个维度数组，未知字段忽略。Runtime 使用准备批次
自己的 identity，处理顺序为：

1. JSON extraction / tolerant decode。
2. item ID 去重、当前批次范围校验。
3. 允许 partial coverage：返回的有效歌曲立即提交，遗漏歌曲继续 pending。
4. Deterministic Taxonomy Sanitizer：
   - 合法 TagID 接受。
   - displayName / alias 转换为 TagID。
   - 放错维度时归位到 owner dimension。
   - 未知字符串丢弃，不写数据库，不整批失败。
5. Runtime-owned hidden `recommendation_index_commit`。
6. SQLite 写入层再次校验；未知 TagID 在 strict path 拒绝。

数值字段接受安全的整数字符串；越界或不可用值仅丢弃该值。`confidence` 缺失、null、越界
或不可用时使用中性默认值，不使整个批次失败。

## 外部 Evidence

分类请求保持封闭 transform（`tools=[]`、无 hosted tools、无 tool choice）。需要补证时，
`RecommendationIndexSkillRuntime` 在分类前运行只读 Evidence 阶段，通过 skill-only 的
`recommendation_evidence_search` / `recommendation_evidence_fetch` 将结果绑定到具体歌曲。
本地元数据优先，Apple iTunes 先于定向网页检索；Tavily 是可选的 configured backend，
网易云等来源通过 `include_domains` 约束。公开检索必须同时满足 `allowsMetadata` 和
`allowsExternalDiscovery`；失败时继续使用本地资料，不阻断索引。

网页内容始终标记为 `externalUntrusted`，限制为本轮搜索得到的 URL、大小、超时和重定向范围，
不能成为工具创建、歌单修改或其它 mutation authorization 的来源。外部搜索按歌曲和批次
限制调用次数，并缓存成功结果；API Key 只在 Keychain 中保存。

## 数值特征

- `energy`: 1...10。
- `tempo`, `acousticness`, `danceability`, `instrumentalness`, `liveness`,
  `speechiness`, `valence`, `complexity`: 1...5。
- 没有证据时为 `null`，不写该数值维度，不使用默认中间值伪造事实。

## 数据库

- 保留 `recommendation_index_v2_state` 与 `recommendation_index_v2_tags`。
- `tags.value` 存稳定 TagID，例如 `mood.sacred`。
- UI 通过 `RecommendationIndexTaxonomy.displayName(for:)` 显示中文 / 展示名。
- 新 `rulesVersion = "3.0"` 会让旧索引重新分类。
- 迁移删除旧 `dimension='tag'` 数据并清理 `recommendation_index_v2_tag_vocabulary`。

## Agent 推荐

`RecommendationIndexQuery` 支持：

- `includeTags`: 硬过滤。
- `preferTags`: 排序加权。
- `excludeTags`: 排除 / 降权。
- 数值范围过滤。
- 单次 SQL 查询。

Agent 使用 `recommendation_taxonomy_search` / `recommendation_taxonomy_list`
发现固定标签；它们只能返回固定 taxonomy，不能创建标签。
