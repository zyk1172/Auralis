<!-- SPDX-License-Identifier: GPL-3.0-only -->
# Local music folder format

Auralis 的 iOS/iPadOS 可见本地音乐目录采用“**一首歌一个文件夹**”的 package 形式，而不是把所有音频平铺到 `LocalMusic` 根目录。手动导入与服务器下载最终都遵循这套物理目录规范。

## 目录结构

`文件 → 我的 iPhone / 我的 iPad → Auralis → LocalMusic`

```text
LocalMusic/
├── README.txt
├── 夜行/
│   ├── audio.flac
│   ├── cover.jpg
│   ├── lyrics.lrc
│   └── metadata.json
└── Another Song/
    ├── audio.m4a
    ├── cover.png
    ├── lyrics.txt
    └── metadata.json
```

`LocalMusic` 下的每个普通一级子文件夹代表一首本地歌曲。受管理目录不会继续把更深层的任意音频文件当成独立歌曲扫描，从而避免“专辑目录 / 临时文件 / 多版本文件”被错误拆成多首。

从服务器下载的歌曲也会物理落在这里，并采用相同的一歌一文件夹结构；其 `metadata.json` 带有 Auralis 内部的下载所有权标记，因此本地扫描器会跳过该目录，远端歌曲不会因为“可见下载文件”而在统一资料库中重复出现第二次。下载状态、删除和远端兼容身份仍由 DownloadStore / TrackCacheStore 维护。

## 设置中的“导入歌曲”

iOS/iPadOS 的“设置 → 本地音乐 → 导入歌曲”可以选择歌曲文件，也可以选择已经包含一首歌曲的文件夹。导入不是简单保存外部路径，而是复制并规范化到 Auralis 的 `LocalMusic`：

- 读取音频内嵌标题、艺人、专辑、流派和内嵌封面；
- 识别 `cover.*` / `folder.*` / `front.*` / `artwork.*` 与同名图片；
- 识别 `lyrics.lrc` / `lyrics.txt` 与音频同名歌词；
- 读取已有 `metadata.json`；
- 统一输出 `audio.<ext>`、`cover.<ext>`、`lyrics.lrc|txt`、`metadata.json`。

如果直接一次选择多个散落在同一目录的音频文件，Auralis 不会把通用的 `cover.jpg` 或 `lyrics.lrc` 猜给所有歌曲；此时只使用音频同名 sidecar 与音频内嵌信息，避免串封面或串歌词。若选择的是单曲文件夹，则可安全使用该文件夹内的通用 sidecar。

## 文件规则

### 音频

每个普通本地歌曲文件夹必须恰好包含 **1 个**受支持音频文件；0 个或多于 1 个都会把该歌曲 package 标记为扫描失败，避免 Auralis 猜测应该播放哪一个文件。

支持扩展名：`mp3`、`m4a`、`aac`、`alac`、`flac`、`wav`、`aiff` / `aif`、`ogg`、`opus`。

手动建立的 package 中音频文件名可以自由命名；通过“导入歌曲”或服务器下载生成的标准 package 统一使用 `audio.<ext>`。

### 封面

封面作为歌曲 package 的一等 sidecar 文件使用。支持 `jpg`、`jpeg`、`png`、`webp`、`heic`、`heif`。

默认按以下优先级识别：

1. `cover.*`
2. `folder.*`
3. `front.*`
4. `artwork.*`
5. 与音频同名的图片

也可以在 `metadata.json` 中用 `coverFile` 指定当前歌曲文件夹内的具体文件。扫描后，歌曲、专辑和艺人读取路径都能复用该本地封面；封面从本地文件直接进入现有图片解码/缓存管线，不会被错误发送到 OpenSubsonic。

服务器下载会在下载完成后尝试从原服务器取得当前封面并写为 `cover.<ext>`。服务器没有封面或获取失败时不伪造文件，音频仍保持可播放。

### 歌词

歌词支持：

- `.lrc`：支持 `[mm:ss.xx]` / `[mm:ss.xxx]` 时间戳以及一行多个时间戳，作为同步歌词进入现有歌词时间轴。
- `.txt`：作为非同步逐行歌词。

默认优先：`lyrics.lrc` → 音频同名 `.lrc` → `lyrics.txt` → 音频同名 `.txt`。也可以在 `metadata.json` 中用 `lyricsFile` 指定当前歌曲文件夹内的具体文件。

本地歌词会进入 `LibraryCatalog.lyrics`，因此 Now Playing / 歌词界面可以直接使用 sidecar 内容。服务器下载在完成后会尝试获取服务器歌词：有时间轴时写为 LRC，否则写为 TXT；服务器没有歌词或暂时不可达不会让音频下载失败。

### metadata.json

`metadata.json` 用于补齐或覆盖音频标签。手动 package 可以省略；“导入歌曲”和服务器下载会主动生成规范化文件。例如：

```json
{
  "title": "夜行",
  "artist": "测试艺人",
  "album": "测试专辑",
  "year": 2026,
  "trackNumber": 2,
  "discNumber": 1,
  "genres": ["Electronic", "Pop"],
  "language": "zh-Hans",
  "coverFile": "cover.jpg",
  "lyricsFile": "lyrics.lrc"
}
```

读取优先级是：`metadata.json > 音频内嵌标签 > 文件夹 / 文件名回退值`。

`coverFile` 与 `lyricsFile` 只允许引用当前歌曲文件夹中的单个文件名，不接受跨目录路径。服务器下载生成的 metadata 还会写入内部所有权和远端身份字段，这些字段由 Auralis 管理，用户无需手工维护。

## 下载文件与缓存身份

服务器歌曲完成下载后，音频不会在内部缓存和 Files 目录各留一份。Auralis 先完成可靠的后台下载，再把同一份音频**移动**到标准 package，并让 TrackCacheStore 的索引指向新的文件位置，因此：

- Files 中可以直接看到真实下载文件；
- 播放、离线状态和删除下载继续使用原有缓存接口；
- 删除下载会删除整个受管理歌曲文件夹；
- 旧版本已经存在于内部缓存中的下载会在能重新取得服务器元数据时逐步迁移；离线时保留原缓存，等以后再迁移。

对于服务器下载 package，建议通过 Auralis 的“删除下载”操作清理，不要直接在 Files 中删除，以便下载索引和物理文件保持一致。

## 缺失 sidecar 时

音频文件是 package 的硬性要求。封面与歌词是受支持的标准 sidecar，但不会为了缺封面或无歌词（例如纯音乐）而拒绝播放：没有封面时使用现有占位封面，没有歌词时正常播放，没有 `metadata.json` 的手动 package 则继续使用音频标签和文件夹名推断。

## 兼容性

严格的一歌一文件夹规则用于 iOS/iPadOS 自动管理、Files 可见的 `Documents/LocalMusic` 来源。

历史上已经保存的 Apple security-scoped 外部文件夹仍保持递归音频扫描兼容，避免升级后破坏用户原有目录；这些外部目录同样可以读取同目录封面、歌词和 `metadata.json` sidecar。macOS 仍保留显式文件夹授权模式；Android 的 SAF 本地音乐行为不由本次 Apple 目录变更修改。
