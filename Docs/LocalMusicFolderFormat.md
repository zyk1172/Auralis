<!-- SPDX-License-Identifier: GPL-3.0-only -->
# Local music folder format

Auralis 的 iOS/iPadOS 可见本地音乐目录采用“**一首歌一个文件夹**”的 package 形式，而不是把所有音频平铺到 `LocalMusic` 根目录。

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
    ├── song.m4a
    ├── artwork.png
    └── lyrics.txt
```

`LocalMusic` 下的**每个一级子文件夹代表一首歌**。受管理目录不会继续把更深层的任意音频文件当成独立歌曲扫描，从而避免“专辑目录 / 临时文件 / 多版本文件”被错误拆成多首。

## 文件规则

### 音频

每个歌曲文件夹必须恰好包含 **1 个**受支持音频文件；0 个或多于 1 个都会把该歌曲 package 标记为扫描失败，避免 Auralis 猜测应该播放哪一个文件。

支持扩展名：

- `mp3`
- `m4a`
- `aac`
- `alac`
- `flac`
- `wav`
- `aiff` / `aif`
- `ogg`
- `opus`

音频文件名不固定，可以叫 `audio.flac`、`song.m4a` 或歌曲名本身。

### 封面

封面作为歌曲 package 的一等 sidecar 文件使用。支持 `jpg`、`jpeg`、`png`、`webp`、`heic`、`heif`。

默认按以下优先级识别：

1. `cover.*`
2. `folder.*`
3. `front.*`
4. `artwork.*`
5. 与音频同名的图片，例如 `夜行.flac` + `夜行.jpg`

也可以在 `metadata.json` 中用 `coverFile` 指定当前歌曲文件夹内的具体文件。

扫描后，歌曲、专辑和艺人读取路径都能复用该本地封面；封面从本地文件直接进入现有图片解码/缓存管线，不会被错误发送到 OpenSubsonic。

### 歌词

歌词支持：

- `.lrc`：支持 `[mm:ss.xx]` / `[mm:ss.xxx]` 时间戳以及一行多个时间戳，作为同步歌词进入现有歌词时间轴。
- `.txt`：作为非同步逐行歌词。

默认优先：

1. `lyrics.lrc`
2. 与音频同名的 `.lrc`
3. `lyrics.txt`
4. 与音频同名的 `.txt`

也可以在 `metadata.json` 中用 `lyricsFile` 指定当前歌曲文件夹内的具体文件。

本地歌词会进入 `LibraryCatalog.lyrics`，因此 Now Playing / 歌词界面优先直接使用 sidecar 内容，不需要向服务器请求歌词。

### metadata.json

`metadata.json` 可选。它用于补齐或覆盖音频标签，适合标签缺失、编码不统一或需要明确本地展示信息的文件：

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

优先级是：

`metadata.json > 音频内嵌标签 > 文件夹 / 文件名回退值`

`coverFile` 与 `lyricsFile` 只允许引用当前歌曲文件夹中的单个文件名，不接受跨目录路径。

## 缺失 sidecar 时

音频文件是 package 的硬性要求。封面与歌词是受支持的标准 sidecar，但不会为了缺封面或无歌词（例如纯音乐）而拒绝播放：

- 没有封面：使用现有占位封面。
- 没有歌词：歌曲正常播放，歌词视图显示无歌词。
- 没有 `metadata.json`：继续使用音频标签和文件夹名推断。

## 兼容性

这个严格的一歌一文件夹规则用于 iOS/iPadOS 自动管理、Files 可见的 `Documents/LocalMusic` 来源。

历史上已经保存的 Apple security-scoped 外部文件夹仍保持递归音频扫描兼容，避免升级后破坏用户原有目录；这些外部目录同样可以读取同目录封面、歌词和 `metadata.json` sidecar。服务器下载仍由独立下载存储管理，不会被这个用户导入目录重复扫描。
