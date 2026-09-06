# Auralis 本地权威目录（SQLite）与持久化层审计 — Android/Room 迁移规格

> 审计对象：Apple 端 `Packages/AuralisCore/Sources/LocalCatalog/*`、`MusicLibrary/LibrarySync.swift`、`Persistence/*`、`SecurityKit/*`、`AppShell/*`。
> 只读审计，未做任何修改。所有 SQL 均逐字引用自 `LocalCatalogStore.swift` 的 `createSchema()`（行 68–321）。
> `GlobalID` 字符串格式：`"serverID:remoteID"`（`GlobalID.swift:25`）。这是所有实体的本地主键编码方式，**多服务器隔离的根基**。

---

## 1. 完整数据库 Schema

数据库由 `LocalCatalogStore.createSchema()` 用 `CREATE TABLE IF NOT EXISTS` 一次性建表（`LocalCatalogStore.swift:63-322`）。无 `user_version` PRAGMA，版本号由自管理表 `catalog_migrations` 记录（见第 2 节）。

### 1.1 实体主表（servers / artists / albums / tracks / genres / playlists）

```sql
CREATE TABLE IF NOT EXISTS servers (
    global_id TEXT PRIMARY KEY,
    server_id TEXT NOT NULL,
    remote_id TEXT NOT NULL,
    name TEXT NOT NULL,
    base_url TEXT,
    username TEXT,
    payload TEXT NOT NULL,
    updated_at REAL NOT NULL
);
CREATE TABLE IF NOT EXISTS artists (
    global_id TEXT PRIMARY KEY,
    server_id TEXT NOT NULL,
    remote_id TEXT NOT NULL,
    name TEXT NOT NULL,
    payload TEXT NOT NULL,
    updated_at REAL NOT NULL
);
CREATE TABLE IF NOT EXISTS albums (
    global_id TEXT PRIMARY KEY,
    server_id TEXT NOT NULL,
    remote_id TEXT NOT NULL,
    name TEXT NOT NULL,
    artist_name TEXT NOT NULL,
    artist_gid TEXT,
    payload TEXT NOT NULL,
    updated_at REAL NOT NULL
);
CREATE TABLE IF NOT EXISTS tracks (
    global_id TEXT PRIMARY KEY,
    server_id TEXT NOT NULL,
    remote_id TEXT NOT NULL,
    title TEXT NOT NULL,
    artist_name TEXT NOT NULL,
    album_title TEXT NOT NULL,
    album_gid TEXT,
    artist_gid TEXT,
    duration REAL NOT NULL,
    payload TEXT NOT NULL,
    updated_at REAL NOT NULL
);
CREATE TABLE IF NOT EXISTS genres (
    global_id TEXT PRIMARY KEY,
    server_id TEXT NOT NULL,
    remote_id TEXT NOT NULL,
    name TEXT NOT NULL,
    payload TEXT NOT NULL,
    updated_at REAL NOT NULL
);
CREATE TABLE IF NOT EXISTS playlists (
    global_id TEXT PRIMARY KEY,
    server_id TEXT NOT NULL,
    remote_id TEXT NOT NULL,
    name TEXT NOT NULL,
    is_readonly INTEGER NOT NULL DEFAULT 0,
    payload TEXT NOT NULL,
    updated_at REAL NOT NULL
);
CREATE TABLE IF NOT EXISTS playlist_tracks (
    playlist_gid TEXT NOT NULL,
    position INTEGER NOT NULL,
    track_gid TEXT NOT NULL,
    PRIMARY KEY (playlist_gid, position)
);
```

> `payload` 是完整 `Track`/`Album`/`Artist`/`Playlist`/`ServerAccount` 的 JSON 序列化（见 `encode:`/`decode:`，`LocalCatalogStore.swift:1046-1059`）。Room 迁移时可保留为 `@ColumnInfo(typeAffinity = TEXT)` 原样落地，业务字段从 payload 解析。
> `artists/albums/tracks` 另有实体外键列 `artist_gid`/`album_gid`（`albums.artist_gid`、`tracks.album_gid`/`tracks.artist_gid`），由 R03 迁移补列回填（见 2.3）。

### 1.2 标注类表（favorites / ratings / play_history / downloads / lyrics / disliked_tracks）

```sql
CREATE TABLE IF NOT EXISTS favorites (
    global_id TEXT PRIMARY KEY,
    kind TEXT NOT NULL,
    value INTEGER NOT NULL,
    updated_at REAL NOT NULL
);
CREATE TABLE IF NOT EXISTS ratings (
    global_id TEXT PRIMARY KEY,
    value INTEGER NOT NULL,
    updated_at REAL NOT NULL
);
CREATE TABLE IF NOT EXISTS play_history (
    global_id TEXT PRIMARY KEY,
    last_played REAL NOT NULL,
    play_count INTEGER NOT NULL,
    completed INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS downloads (
    global_id TEXT PRIMARY KEY,
    state TEXT NOT NULL,
    local_path TEXT,
    updated_at REAL NOT NULL
);
CREATE TABLE IF NOT EXISTS lyrics (
    global_id TEXT PRIMARY KEY,
    payload TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS disliked_tracks (
    global_id TEXT PRIMARY KEY,
    server_id TEXT NOT NULL,
    created_at REAL NOT NULL,
    source TEXT
);
```

> **关键隔离特征**：`favorites`/`ratings`/`play_history`/`downloads`/`lyrics` **没有 `server_id` 列**，主键 `global_id` 本身已是 `"serverID:remoteID"`，因此多服务器隔离完全依赖主键字符串前缀。Android 实现要么保留此约定，要么为这些表补 `server_id` 列（推荐，便于按服务器批量清理与索引）。`disliked_tracks` 已带 `server_id`。

### 1.3 同步状态表（sync_checkpoints / sync_sessions / sync_staged_* / sync_meta）

```sql
CREATE TABLE IF NOT EXISTS sync_checkpoints (
    session_id TEXT NOT NULL,
    server_id TEXT NOT NULL,
    section TEXT NOT NULL,
    continuation TEXT,
    source_revision TEXT,
    processed_count INTEGER NOT NULL,
    completed_at REAL,
    updated_at REAL NOT NULL,
    PRIMARY KEY (session_id, section)
);
CREATE TABLE IF NOT EXISTS sync_sessions (
    session_id TEXT PRIMARY KEY,
    server_id TEXT NOT NULL UNIQUE,
    mode TEXT NOT NULL,
    started_at REAL NOT NULL
);
CREATE TABLE IF NOT EXISTS sync_staged_artists (
    session_id TEXT NOT NULL,
    global_id TEXT NOT NULL,
    server_id TEXT NOT NULL,
    remote_id TEXT NOT NULL,
    name TEXT NOT NULL,
    payload TEXT NOT NULL,
    updated_at REAL NOT NULL,
    PRIMARY KEY (session_id, global_id)
);
CREATE TABLE IF NOT EXISTS sync_staged_albums (
    session_id TEXT NOT NULL,
    global_id TEXT NOT NULL,
    server_id TEXT NOT NULL,
    remote_id TEXT NOT NULL,
    name TEXT NOT NULL,
    artist_name TEXT NOT NULL,
    artist_gid TEXT,
    payload TEXT NOT NULL,
    updated_at REAL NOT NULL,
    PRIMARY KEY (session_id, global_id)
);
CREATE TABLE IF NOT EXISTS sync_staged_tracks (
    session_id TEXT NOT NULL,
    global_id TEXT NOT NULL,
    server_id TEXT NOT NULL,
    remote_id TEXT NOT NULL,
    title TEXT NOT NULL,
    artist_name TEXT NOT NULL,
    album_title TEXT NOT NULL,
    album_gid TEXT,
    artist_gid TEXT,
    duration REAL NOT NULL,
    payload TEXT NOT NULL,
    updated_at REAL NOT NULL,
    PRIMARY KEY (session_id, global_id)
);
CREATE TABLE IF NOT EXISTS sync_meta (
    server_id TEXT PRIMARY KEY,
    mode TEXT,
    last_completed_at REAL,
    last_processed_count INTEGER NOT NULL DEFAULT 0,
    next_retry_at REAL,
    remote_fingerprint TEXT,
    remote_probe_kind TEXT,
    last_probe_at REAL,
    last_validated_at REAL
);
```

> `sync_sessions` 主键是 `session_id`（UUID），但 `server_id` 为 `UNIQUE`，保证每服务器仅一个活动会话。`sync_staged_*` 是临时暂存区，仅在 `completeSync` / `discardSync` 时清空（见第 4 节）。

### 1.4 推荐索引 / 外部音乐标识 / 社区数据表

```sql
CREATE TABLE IF NOT EXISTS recommendation_index_v2_state (
    global_id TEXT PRIMARY KEY,
    server_id TEXT NOT NULL,
    source_hash TEXT NOT NULL,
    rules_version TEXT NOT NULL,
    classifier TEXT NOT NULL,
    classified_at REAL NOT NULL,
    source_hash_version INTEGER NOT NULL DEFAULT 0,
    semantic_tag_rules_version INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS recommendation_index_v2_tags (
    global_id TEXT NOT NULL,
    dimension TEXT NOT NULL,
    value TEXT NOT NULL,
    confidence REAL NOT NULL,
    PRIMARY KEY (global_id, dimension, value)
);
CREATE TABLE IF NOT EXISTS catalog_migrations (
    key TEXT PRIMARY KEY,
    version INTEGER NOT NULL,
    applied_at REAL NOT NULL
);
CREATE TABLE IF NOT EXISTS catalog_runtime_metadata (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL,
    updated_at REAL NOT NULL
);
CREATE TABLE IF NOT EXISTS recommendation_index_v2_tag_vocabulary (
    normalized_key TEXT PRIMARY KEY,
    display_value TEXT NOT NULL,
    created_at REAL NOT NULL,
    updated_at REAL NOT NULL
);
CREATE TABLE IF NOT EXISTS external_music_identities (
    global_track_id TEXT PRIMARY KEY,
    recording_mbid TEXT,
    release_mbid TEXT,
    release_group_mbid TEXT,
    artist_mbid TEXT,
    isrc TEXT,
    match_confidence REAL NOT NULL,
    match_method TEXT NOT NULL,
    matcher_revision INTEGER,
    verified_at REAL NOT NULL
);
CREATE TABLE IF NOT EXISTS external_music_candidates (
    global_track_id TEXT NOT NULL,
    recording_mbid TEXT NOT NULL,
    payload TEXT NOT NULL,
    confidence REAL NOT NULL,
    created_at REAL NOT NULL,
    PRIMARY KEY (global_track_id, recording_mbid)
);
CREATE TABLE IF NOT EXISTS community_music_metrics (
    global_track_id TEXT NOT NULL,
    source TEXT NOT NULL,
    payload TEXT NOT NULL,
    fetched_at REAL NOT NULL,
    status TEXT NOT NULL,
    PRIMARY KEY (global_track_id, source)
);
CREATE TABLE IF NOT EXISTS community_music_evidence (
    global_track_id TEXT PRIMARY KEY,
    payload TEXT NOT NULL,
    fetched_at REAL NOT NULL
);
CREATE TABLE IF NOT EXISTS community_music_reviews (
    global_track_id TEXT NOT NULL,
    source TEXT NOT NULL,
    review_id TEXT NOT NULL,
    payload TEXT NOT NULL,
    fetched_at REAL NOT NULL,
    PRIMARY KEY (global_track_id, source, review_id)
);
```

> 外部音乐/社区数据主键均为 `global_track_id`（含 serverID），无独立 `server_id` 列，隔离同样依赖主键前缀。
> `recommendation_index_v2_*` 为推荐索引 v3（固定分类法）实现，语义标签（dimension='tag'）已废弃（`LocalCatalogModels.swift` 相关 `@available(*, deprecated)`）。

### 1.5 全文检索虚拟表（FTS5）

```sql
CREATE VIRTUAL TABLE IF NOT EXISTS catalog_fts USING fts5(kind UNINDEXED, global_id UNINDEXED, text);
```

> `catalog_fts` 无 `server_id` 列；按服务器隔离靠 `DELETE FROM catalog_fts WHERE global_id LIKE 'serverID:%'`（见 `completeSync` / `purgeServer`）。Android 可用 Room FTS4/FTS5 虚拟表等价实现，`text` 列存 `'title artist album'`。

### 1.6 索引（createSchema 内 `CREATE INDEX IF NOT EXISTS`）

```sql
CREATE INDEX IF NOT EXISTS idx_tracks_server ON tracks(server_id);
CREATE INDEX IF NOT EXISTS idx_albums_server ON albums(server_id);
CREATE INDEX IF NOT EXISTS idx_artists_server ON artists(server_id);
CREATE INDEX IF NOT EXISTS idx_playlists_server ON playlists(server_id);
CREATE INDEX IF NOT EXISTS idx_sync_checkpoints_server ON sync_checkpoints(server_id);
CREATE INDEX IF NOT EXISTS idx_sync_staged_artists_session ON sync_staged_artists(session_id);
CREATE INDEX IF NOT EXISTS idx_sync_staged_albums_session ON sync_staged_albums(session_id);
CREATE INDEX IF NOT EXISTS idx_sync_staged_tracks_session ON sync_staged_tracks(session_id);
CREATE INDEX IF NOT EXISTS idx_recommendation_v2_state_server ON recommendation_index_v2_state(server_id);
CREATE INDEX IF NOT EXISTS idx_recommendation_v2_tags_dimension_value ON recommendation_index_v2_tags(dimension, value);
CREATE INDEX IF NOT EXISTS idx_external_identity_recording ON external_music_identities(recording_mbid);
CREATE INDEX IF NOT EXISTS idx_external_candidates_track ON external_music_candidates(global_track_id, confidence DESC);
CREATE INDEX IF NOT EXISTS idx_community_metrics_track ON community_music_metrics(global_track_id, fetched_at DESC);
CREATE INDEX IF NOT EXISTS idx_disliked_tracks_server ON disliked_tracks(server_id);
CREATE INDEX IF NOT EXISTS idx_community_reviews_track ON community_music_reviews(global_track_id, fetched_at DESC);
```

> R03 实体关系索引在迁移阶段创建（非建表阶段，原因见 `LocalCatalogStore.swift:64-67` 注释）：

```sql
CREATE INDEX IF NOT EXISTS idx_tracks_album_gid ON tracks(album_gid);
CREATE INDEX IF NOT EXISTS idx_tracks_artist_gid ON tracks(artist_gid);
CREATE INDEX IF NOT EXISTS idx_albums_artist_gid ON albums(artist_gid);
```

### 1.7 连接期 PRAGMA（`SQLiteDatabase.swift:60-79`）

```sql
PRAGMA journal_mode = WAL;       -- 写前开启 WAL
PRAGMA foreign_keys = ON;        -- 外键约束开启（注意建表未声明 FOREIGN KEY，仅开启开关）
PRAGMA busy_timeout = 5000;      -- App Group 共享库并发写保护，5000ms
```

> Android Room 对应：使用 `SQLiteOpenHelper` 时可在 `onConfigure` 执行 `PRAGMA foreign_keys=ON`、`PRAGMA busy_timeout`，并用 `SQLiteDatabase` 的 WAL 模式（`enableWriteAheadLogging()`）。

---

## 2. 迁移机制

### 2.1 版本管理：不使用 `user_version`，使用自管理 `catalog_migrations` 表

`SQLiteDatabase` 从未读取/写入 `PRAGMA user_version`。版本号记录在 `catalog_migrations(key, version, applied_at)`（`LocalCatalogStore.swift:242-246`），每个迁移步骤用唯一 `key` 记录已应用版本，启动时用 `SELECT version FROM catalog_migrations WHERE key = ?` 判断是否需要执行（`LocalCatalogStore.swift:331-335`）。

> 注意：存在另一套独立版本体系 `AuralisSchema`（currentVersion=2，`Persistence.swift:14-23`），它只服务于**遗留文件归档 `FileBackedPersistence`**（`library.json` 迁移，v1→v2 仅补 account/checkpoint）。与 SQLite 目录无关，Android 不必迁移该文件，应直接以 SQLite 目录为准。

### 2.2 启动期迁移编排（`LocalCatalogStore.init`，`LocalCatalogStore.swift:20-33`）

顺序：`createSchema()` → `cleanupOrphanedSyncState()` → `runAdditiveSchemaMigrations()` → `runEntityRelationMigrations()` → `runCatalogMigrations()`。

### 2.3 三类迁移

- **A. 增量补列 `runAdditiveSchemaMigrations`（targetVersion = 3，`LocalCatalogStore.swift:326-365`）**
  通过 `PRAGMA table_info(<table>)` 检查列是否存在，缺失才 `ALTER TABLE ... ADD COLUMN`（`addColumnIfMissing`，`LocalCatalogStore.swift:367-376`）。补列：
  - `recommendation_index_v2_state.source_hash_version` / `semantic_tag_rules_version`（`INTEGER NOT NULL DEFAULT 0`）
  - `sync_meta.remote_fingerprint` / `remote_probe_kind` / `last_probe_at` / `last_validated_at`（`TEXT`/`REAL`）
  - `external_music_identities.matcher_revision`（`INTEGER`）
  - 版本 3 因 `matcher_revision` 在某些已存在 version=2 的库上需重跑而提升（`LocalCatalogStore.swift:328-330`）。

- **B. 实体关系 `runEntityRelationMigrations`（两阶段 v1→v2，`LocalCatalogStore.swift:389-424`）**
  - v1（补列 + 名称猜测回填）：`tracks.album_gid`/`artist_gid`、`albums.artist_gid`、`sync_staged_*` 对应列；再按「server_id + 名称」猜测回填（仅填 NULL 行），建实体关系索引，记录 version=1。
  - v2（payload 权威修复）：从 `tracks.payload`/`albums.payload` 解码真实 `albumID`/`artistID`，**强制覆盖** gid（含 v1 猜测错值），记录 version=2。每阶段独立 `db.transaction`，失败整体回滚。

- **C. `runCatalogMigrations()`**：审计时为空壳（`LocalCatalogStore.swift:31`），保留扩展位。

版本行写入用 `INSERT ... ON CONFLICT(key) DO UPDATE`（幂等，`recordMigrationVersion`，`LocalCatalogStore.swift:551-559`）。

### 2.4 打开/迁移失败行为：不删库

- `SQLiteDatabase.init` 在 `sqlite3_open` 失败或任一 PRAGMA 失败时，**仅 `sqlite3_close_v2` 句柄并抛出 `LocalCatalogError.openFailed`**（`SQLiteDatabase.swift:42-79`），**绝不删除 `.sqlite` 文件**。
- `LocalCatalogStore.init` 将异常向上抛出，App 无法构造 store，但磁盘库保留。
- `verifyIntegrityIfDue`（`LocalCatalogStore.swift:563-596`）按时间策略（默认 7 天，`integrityCheckMinimumInterval`）后台执行 `PRAGMA quick_check`，失败只抛错记录，**不删库、不在打开时强制校验**。
- 遗留文件归档 `FileBackedPersistence` 对损坏存档抛 `PersistenceError.corruptArchive`（同样不删）。

> Android 建议：Room 的 `Migration` 策略对应 A/B/C；但 Auralis 用 `IF NOT EXISTS` + `ADD COLUMN IF MISSING` 的「幂等补列」模式，Room 可直接用 `Migration` 逐版 `ALTER TABLE`，或采用同款「`catalog_migrations` 自管理 + 启动幂等补列」方案以 1:1 对齐。

---

## 3. 主键与身份

| 表 | 主键 | 是否含 serverID | 说明 |
|---|---|---|---|
| servers | `global_id` | ✅ | = `serverID:serverID`（remote_id 同值） |
| artists / albums / tracks / genres / playlists | `global_id` | ✅ | `"serverID:remoteID"` |
| playlist_tracks | `(playlist_gid, position)` | ✅ | `playlist_gid` 含 serverID |
| favorites / ratings / play_history / downloads / lyrics | `global_id` | ✅ | 主键字符串含 serverID（表无 server_id 列） |
| disliked_tracks | `global_id` | ✅ | 另有 `server_id` 列 + 索引 |
| sync_checkpoints | `(session_id, section)` | 间接 | `session_id`→`sync_sessions.server_id` 间接定位 |
| sync_sessions | `session_id` | 间接 | `server_id UNIQUE`，每服务器一个会话 |
| sync_staged_* | `(session_id, global_id)` | 间接 | 行内另有 `server_id` 列 |
| sync_meta | `server_id` | ✅ | 显式 server_id |
| recommendation_index_v2_state | `global_id` | ✅ | 另有 `server_id` 列 |
| recommendation_index_v2_tags | `(global_id, dimension, value)` | ✅ | |
| catalog_migrations / catalog_runtime_metadata | `key` | ❌ | 全局元配置，非按服务器 |
| recommendation_index_v2_tag_vocabulary | `normalized_key` | ❌ | 全局词表 |
| external_music_identities / community_music_* | `global_track_id` / 复合 | ✅ | 含 serverID 主键 |
| catalog_fts | 无显式 PK | ✅ | 靠 `global_id` 前缀隔离 |

**结论：没有「只用 remote id 做主键」的表。** 所有业务表主键都通过 `global_id = "serverID:remoteID"` 复合字符串纳入 serverID，或以显式 `server_id` 列参与。唯一的纯全局键（`catalog_migrations`、`catalog_runtime_metadata`、`tag_vocabulary`）是跨服务器共享的元数据，不涉及单服务器数据。

---

## 4. 同步语义（LibrarySync.swift + LocalCatalogStore）

### 4.1 分页与流程参数

- 分页大小 **pageSize = 250**（默认，`LibrarySync.swift:265`；`LibrarySynchronizer.init` 参数）。
- 每 section 最大页数 `maximumPagesPerSection = 100_000`（防死循环，`LibrarySync.swift:266`）。
- 重试策略 `LibrarySyncRetryPolicy`：最多 3 次，指数退避 250ms→4s（`LibrarySync.swift:123-149`）。
- section 顺序固定 `artists → albums → tracks`（`LibrarySyncSection.allCases`，`LibrarySync.swift:304`）。

### 4.2 阶段 / checkpoint / commit 流程

1. `beginSync`：复用或新建 `sync_sessions` 行（同服务器同模式才复用，否则 `discardSyncState` 后新建，`LocalCatalogStore.swift:609-640`）。
2. 每 section：`checkpoint(session, section)` 读取断点 → 循环 `fetch → validate → stage → saveCheckpoint`，直到 `continuation == nil`（`LibrarySync.swift:368-465`）。
   - `stage*` 在单 `db.transaction` 内 `INSERT OR REPLACE INTO sync_staged_*`（带 serverID 校验，错误服务器抛 `invalidRecordServer`，`LocalCatalogStore.swift:707-797`）。
   - `saveCheckpoint` 用 `ON CONFLICT(session_id, section) DO UPDATE` 持久化 `continuation`/`sourceRevision`/`processed_count`/`completed_at`（`LocalCatalogStore.swift:799-827`）。
3. `completeSync`（全段完成后，`LocalCatalogStore.swift:829-909`）：
   - 在单 `db.transaction` 内：**先 `DELETE FROM artists/albums/tracks WHERE server_id = ?`**，再从 `sync_staged_*` `INSERT OR REPLACE` 回主表；重建该服务器 `catalog_fts`；更新 `sync_meta`（last_completed_at、last_processed_count、next_retry_at=NULL）；最后 `discardSyncState` 清空暂存。
   - 关键语义：**OpenSubsonic 的“增量”实际仍是全量遍历**（staging 覆盖整库），故每次完成同步都先删后插，确保服务器已删除的曲目在本地消失（`LocalCatalogStore.swift:838-846` 注释明确）。真正的 delta API 接入前，incremental 模式不应改为“不删除”。

### 4.3 失败是否回滚

- `stage*` / `completeSync` / 各迁移都在 `db.transaction`（`BEGIN IMMEDIATE` … `COMMIT`，异常 `ROLLBACK`，`SQLiteDatabase.swift:164-173`）内 → **失败自动回滚**，读者不会看到半套目录。
- 但 `LibrarySynchronizer.sync` 出错时调用 `suspendSync`（**保留** session + staged + checkpoints，`LocalCatalogStore.swift:911-914`、`LibrarySync.swift:337-340`），不 `discardSync`。下次进程复用同一 SQLite 库，从最后 durable `continuation` 续传。只有显式 `discardSync`/`discardSuspendedSync` 才清暂存。
- `cleanupOrphanedSyncState`（`LocalCatalogStore.swift:600-605`）启动期清理无对应 `sync_sessions` 的孤儿 checkpoint/staged 行。

### 4.4 增量判断 / sync_state 内容

- 增量判断不靠行级 diff，而是：续传用 `continuation`（opaque offset/token，来自网络适配器）+ `sourceRevision`（`previousRevision`）；变更探测用 `sync_meta.remote_fingerprint`（`recordRemoteProbe`，`LocalCatalogStore.swift:656-686`）。
- `sync_meta` 存：每服务器 `mode`、`last_completed_at`、`last_processed_count`、`next_retry_at`、`remote_fingerprint`、`remote_probe_kind`、`last_probe_at`、`last_validated_at`。
- `CatalogSyncStatus`（`LocalCatalogModels.swift:26-52`）据 `last_completed_at` 与 `staleAfter`（默认 7 天）计算 `isStale`，驱动启动/回前台决定是否重拉。

---

## 5. 多服务器隔离

**隔离根基**：所有主键为 `"serverID:remoteID"`，且 `artists/albums/tracks/genres/playlists` 均有 `server_id` 列与索引。

**查询普遍带 `server_id`**：`allTracks/allAlbums/allArtists`（`server_id = ?`，`CatalogReader.swift:66-182`）、`trackCount`、`replaceFavoriteTracks`（前缀 `LIKE 'serverID:%'`）、`ratings(serverID:)`、`purgeServer`、`completeSync` 删除均按 `server_id` 限定。

**跨数据风险点（迁移需注意）**：
1. `favorites`/`ratings`/`play_history`/`downloads`/`lyrics` **无 `server_id` 列**，隔离纯靠主键前缀。Android 推荐为这些表补 `server_id` 列并建索引，避免 `ratings(serverID:)` 这类「全表读出内存再按前缀过滤」（`CatalogReader.swift:434-444`）在大库下低效/误串。
2. `catalog_fts` 无 server 列，按 `global_id LIKE 'serverID:%'` 删除（`LocalCatalogStore.swift:878`）。
3. `listPlaylists` / `listServers` 加载全表再按 `gid.serverID` 内存过滤（`CatalogReader.swift:302-341`）——功能正确但无 SQL 级 server 过滤，Android 应下沉 `WHERE server_id = ?`。
4. `servers` 表 `global_id = serverID:serverID`，`remote_id` 与 `server_id` 同值；`upsertServer` 用 `global_id`（`LocalCatalogStore.swift:1025-1042`）。
5. `tracksForAlbum`/`tracksForArtist` 用真实 `album_gid`/`artist_gid` 关联（非名称），同名异艺术家不会串歌（`CatalogReader.swift:362-386`）——Android 必须保留 `album_gid`/`artist_gid` 外键列。

---

## 6. DataStore / UserDefaults 等价物（设置项键名与类型）

`Persistence.swift` 本身只是 `AuralisPersisting` 协议 + `InMemoryPersistence`/`FileBackedPersistence` 实现，**不含任何 UserDefaults 键**。真实键值分散在 AppShell，下面列出需迁移到 Android `DataStore`/`SharedPreferences` 的键（均为 `UserDefaults`，`standard` 或 `@AppStorage`）：

| Key | 类型 | 来源 |
|---|---|---|
| `auralis.homeLayout.v1` | Data(JSON: `HomeLayoutPreference`) | `HomeLayoutStore.defaultsKey`（首页布局 quickEntries/contentModules） |
| `auralis.recentSearches` | Array\<String\> | `AuralisAppModel.recentSearchesDefaultsKey`（最近搜索，运行时上限保留） |
| `auralis.ai.enabled` | Bool | `SettingsView/AssistantView` |
| `auralis.ai.allowsMetadata` / `allowsLyrics` / `allowsHistory` / `allowsFavoritesAndRatings` | Bool | `SettingsDetailPages.swift:331-334` |
| `auralis.audio.highQualityWiFi` / `auralis.audio.cellularTranscoding` | Bool | `SettingsDetailPages.swift:73-74`，另 `StreamQualityPolicy.highQualityWiFiKey`/`cellularTranscodingKey` |
| `auralis.agent.scene` | String | `SettingsDetailPages.swift:564` |
| `auralis.agent.repeatTolerance` | String(`allow`/…) | `SettingsDetailPages.swift:571` |
| `auralis.debug.crashLogEnabled` | Bool | `MacSettingsWindow.swift:493` |
| `auralis.miniplayer.hideArtwork` | Bool | `MacMiniPlayerView.swift:14` |
| `AIConnectionSettings.Keys.*`（baseURL / apiPath / model / endpointMode / maxContextTokens / maxOutputTokens / reasoningMode / reasoningEffort / hasKnownContextWindow / reasoningEnabled） | String/Int/Bool | `AIConnectionSettings`（`SettingsView.swift:649-657`） |
| `AIPrivacyPermissions.externalDiscoveryDefaultsKey` | Bool | `SettingsDetailPages.swift:335` |
| `AISettings.Keys.verifiedCapabilities` | Data | `AISettings.swift:318/347` |
| `TavilySettings.enabledKey` | Bool | `AgentCoordinator.swift:175` |
| `ExternalMusicPreferences.Keys.*`（enabled / musicBrainz / critiqueBrainz / listenBrainz） | Bool | `PlayerViews.swift:996-999` |
| `MusicHapticsCoordinator.enabledDefaultsKey` | Bool | `SettingsDetailPages.swift:75` |
| `MoviePilotSettings.baseURLKey` / `externalBaseURLKey` | String | `MoviePilotSettingsSection.swift:8-9` |
| `AgentCoordinator.consentGivenDefaultsKey` | Bool | `AgentCoordinator.swift:1534/1602` |

> **当前服务器 id：未持久化到 UserDefaults。** `activeServerID` 是 `ProductionServerConnector`/`LibraryCatalog` 的**运行时内存态**（`ProductionServerConnector.swift:35`、`LibraryCatalog.swift:58`），切换服务器即改内存，不写盘。Android 如需“记住上次浏览的服务器”，需自行新增键（建议 `auralis.lastActiveServerID`，String=serverID），否则每次启动默认取 `servers` 表首个或 `tracks` 首个 serverID（`AuralisAppModel.swift:898`）。

---

## 7. 凭据存储（Keychain）

`credentialReference` = `CredentialID`（字符串，`CredentialVault.swift:3-11`，`isValid` 校验非空且无 `\0`）。密码/Token **只存 Keychain，绝不写 UserDefaults**。

**`KeychainCredentialVault`（`KeychainCredentialVault.swift`）映射：**

- `service` = `"com.auralis.player.credentials"`（`defaultService`，`KeychainCredentialVault.swift:7`）
- `kSecClass` = `kSecClassGenericPassword`
- `kSecAttrAccount` = `CredentialID.rawValue`（对服务器即 serverID 字符串）
- `kSecAttrAccessible` = `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`（后台同步可续，不备份、不跨设备，`KeychainCredentialVault.swift:54`）
- `kSecAttrSynchronizable` = `false`（显式关闭 iCloud 同步，`KeychainCredentialVault.swift:167`）
- 可选 `accessGroup`（App Group，目前传 nil；若在 App/扩展共享场景需设 `"group.com.auralis.player"`）

**查/写/删**（原子 upsert，`KeychainCredentialVault.swift:37-97`）：先 `SecItemUpdate`，`errSecItemNotFound` 再 `SecItemAdd`；并发冲突 `errSecDuplicateItem` 重试 update。`delete` 幂等（允许 `errSecItemNotFound`）。

**macOS 降级**（`SystemKeychainBackend.add`，`KeychainCredentialVault.swift:169-181`）：遇 `errSecInteractionNotAllowed` 时移除 synchronizable 标记但**保留 accessibility**，绝不降级为无保护项。

> Android 对应：用 `EncryptedSharedPreferences`（AndroidX Security）或 `Keystore` 等价物；key 用 serverID，无需 service/account 两级（可用单一文件 + key=serverID）。切勿用明文 SharedPreferences。

---

## 8. 文件位置

- **数据库文件名**：`catalog.sqlite`
- **目录**（`LocalCatalogStore.defaultStoreURL`，`LocalCatalogStore.swift:38-59`）：
  - iOS：App Group 容器 `group.com.auralis.player` → `<container>/Auralis/catalog.sqlite`（无 App Group 时回退 `Application Support/Auralis/`）。
  - macOS：沙盒 `~/Library/Application Support/Auralis/catalog.sqlite`（无 App Group，避免付费账号依赖）。
- 扩展名文件：WAL 模式会额外生成 `catalog.sqlite-wal` / `catalog.sqlite-shm`。
- 打开即设 WAL + `foreign_keys=ON` + `busy_timeout=5000`（`SQLiteDatabase.swift:60-79`）。

> Android 建议：将 `catalog.sqlite` 置于 `Context.getDatabasePath("catalog.sqlite")` 或 `noBackupFilesDir`，启用 WAL，使用 Room `SQLiteOpenHelper` 等价 PRAGMA。

---

## 9. Android/Room 实现要点速查

1. 30 张表（含 1 张 FTS5 虚拟表）+ 17 个索引，主键统一 `"serverID:remoteID"` 或显式 `server_id`。
2. 推荐为 `favorites/ratings/play_history/downloads/lyrics/external_music_*/community_music_*` 补 `server_id` 列（原库无），以支持 SQL 级按服务器过滤与索引。
3. 版本管理：优先 1:1 复刻 `catalog_migrations` 自管理 + 启动幂等 `ADD COLUMN IF MISSING`；或 Room `Migration` 逐版。
4. 同步：`pageSize=250`，staging→completeSync 先删后插（不可改为纯增量 INSERT），全程事务。
5. 凭据走 `EncryptedSharedPreferences`/Keystore，不落明文。
6. 设置项迁移上表键值；当前服务器 id 需新增持久化键。
