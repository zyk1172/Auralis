# Recommendation Index V2

Auralis 的 AI 音乐内容索引：固定维度（结构化） + 开放语义标签（无限扩展）。

## 固定维度

- 分类：mood / scene / vocal / texture / style（白名单集合）。
- 数值：energy(1-10) / tempo(1-5) / acousticness(1-5) / danceability(1-5)。
- 版本：`RecommendationIndexV2.rulesVersion`（固定 taxonomy）。

## 开放语义标签（AI 自建）

- 统一维度：`dimension = "tag"`（不允许模型任意创造 dimension 名）。
- value：规范化中文或常见英文标签（如 夜行感 / 公路感 / 城市霓虹 / 复古合成器 / 电影感）。
- **数量没有硬上限**：每首歌多少标签由音乐属性决定；系统 tag 词汇表也没有全局上限。
- 每批 100 首歌（batch limit）与每首歌的标签数量是两个独立概念，绝不混淆。

### 标签质量规则（Agent Prompt 内置）

- 原子语义：一个标签一个概念。
- 不写置信度到文字（value 与 confidence 分离）。
- 禁止用歌曲名 / 艺术家名 / 专辑名 / GlobalID 作为标签。
- 禁止把收藏 / 评分 / 播放历史 / 不喜欢等个人行为写进内容标签。
- 没证据不强造：信息不足时少打标签，不编造具体乐器 / 制作手法 / 情绪。
- 语言统一：默认中文 canonical；行业常见英文（Lo-fi / R&B / City Pop / EDM / Funk）保留。

### 规范化

单一实现 `RecommendationIndexV2.normalizeSemanticTag`：trim → Unicode 规范化 →
去掉前导 `#` → 折叠空白 → 空值过滤。比较按小写归一，避免同义分叉
（`夜行感` / ` 夜行感 ` / `#夜行感` 归一成一条）。

### 存储

`recommendation_index_v2_tags(global_id, dimension, value, confidence)`，
`PRIMARY KEY (global_id, dimension, value)` 保证唯一；写回用 INSERT OR REPLACE。
开放标签统一 `dimension='tag'`。

## 增量升级 / 补标签

- `semanticTagRulesVersion`：只描述开放标签规则版本；旧固定分类不受影响。
- `writeRecommendationIndexV2` 支持 `mode`：
  - `full`（默认）：替换固定维度 + 开放标签；
  - `semanticTagsOnly`：只替换 `dimension='tag'`，绝不删除旧的 mood/style 等固定维度。
- `next_batch` 返回本批 `mode`（full / semanticTagsOnly / mixed），让模型知道该补什么。
- `status` 输出 `semanticTaggedTracks` / `pendingSemanticTagTracks`；pending=0 代表全部完成。

## 词库复用

`library_index_v2_tag_catalog(query?, limit?)`：按需读取已有 canonical 标签及使用次数，
构建时优先复用，避免同义词垃圾场。分页 limit 是单次返回条数，不是系统上限。

## 查询 / 分类浏览

- `library_index_v2_read(dimension, value, limit)`：dimension 允许 `tag`。
- 分类页把 `tag` 作为「AI 标签」分组展示；标签多时用 LazyVGrid/List + 搜索，不一次铺完。

## 传输 / 备份

`RecommendationIndexV2Transfer` 导出全部 tag 行（含 `dimension='tag'` 与 confidence）；
导入时 `tag` 维度经规范化校验后还原。同服务器 + 同歌曲身份匹配后恢复固定与开放标签。
`.auralis-index-v2` 绝不包含密码 / token / URL / 歌词 / 历史 / 评分 / 路径。

## 测试

`RecommendationIndexV2SemanticTagsTests`：3 / 30 / 100 标签、重复与变体归一、
semanticTagsOnly 保留固定维度、导出导入保留开放标签、tag_catalog 读取。
