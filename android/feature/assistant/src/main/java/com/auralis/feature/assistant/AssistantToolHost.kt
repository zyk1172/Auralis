package com.auralis.feature.assistant

import com.auralis.core.ai.AgentToolDescriptor
import com.auralis.core.ai.AgentToolRegistry
import com.auralis.core.ai.SideEffectAuthorizationContext
import com.auralis.core.ai.ToolConfirmationPolicy
import com.auralis.core.ai.ToolSideEffect
import com.auralis.core.data.graph.AuralisGraph
import com.auralis.core.domain.Album
import com.auralis.core.domain.Artist
import com.auralis.core.domain.FavoriteKind
import com.auralis.core.domain.GlobalId
import com.auralis.core.domain.Playlist
import com.auralis.core.domain.QueueEntry
import com.auralis.core.domain.QueueEntryId
import com.auralis.core.domain.ServerId
import com.auralis.core.domain.Track
import com.auralis.core.playback.LocalPlaybackHost
import com.auralis.core.playback.PlaybackController
import com.auralis.core.playback.awaitPlaybackController
import kotlinx.coroutines.flow.first
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.addJsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import kotlinx.serialization.json.putJsonObject

/**
 * AuralisAgentBridge 的 Android 等价物：把**真实可执行**的 canonical 工具登记进注册表。
 *
 * 原则（与 core:ai `AgentToolRegistry` 一致）：
 * - 每个工具都有真实 executor，直连 graph / 播放控制器 / 歌词 / 歌单协调器；
 * - 没有实现对应能力就不注册（不可调用即不可伪造）；
 * - 写操作由上层授权（consent），删除类工具带 Destructive 二次确认；
 * - 工具结果以结构化 JSON 文本回灌给模型。
 *
 * 工具命名与 Swift canonical 完全一致（见 audit/09-assistant.md §3）。
 */
class AssistantToolHost(
    private val graph: AuralisGraph,
) {
    private val registry = AgentToolRegistry()

    private suspend fun activeServerId(): ServerId? =
        runCatching { graph.preferences.activeServerIdValue() }
            .getOrNull()
            ?.takeIf { it.isNotBlank() }
            ?.let { ServerId(it) }

    // ------------------------------------------------------------------
    // 引擎就绪（统一入口 awaitPlaybackController：真实启动播放服务并等待可用；
    // 超时抛异常由工具失败路径如实上报模型，不静默丢弃意图）
    // ------------------------------------------------------------------

    private suspend fun requireEngine(): PlaybackController =
        awaitPlaybackController(startService = { graph.startPlaybackService() })

    // ------------------------------------------------------------------
    // 参数解析（对齐 Swift 形状：globalID {serverID, remoteID} 等）
    // ------------------------------------------------------------------

    private fun Map<String, JsonElement>.string(key: String): String? =
        this[key]?.jsonPrimitive?.contentOrNull

    private fun Map<String, JsonElement>.int(key: String): Int? =
        this[key]?.jsonPrimitive?.contentOrNull?.toIntOrNull()

    private fun Map<String, JsonElement>.double(key: String): Double? =
        this[key]?.jsonPrimitive?.contentOrNull?.toDoubleOrNull()

    /** globalID 参数（接受 serverID/remoteID 或 serverId/remoteId 两种大小写）。 */
    private fun Map<String, JsonElement>.globalId(key: String = "globalID"): GlobalId {
        val node = this[key] ?: throw IllegalArgumentException("缺少参数 $key")
        val obj = node.jsonObject
        val server = obj["serverID"]?.jsonPrimitive?.contentOrNull
            ?: obj["serverId"]?.jsonPrimitive?.contentOrNull
            ?: throw IllegalArgumentException("globalID 缺少 serverID")
        val remote = obj["remoteID"]?.jsonPrimitive?.contentOrNull
            ?: obj["remoteId"]?.jsonPrimitive?.contentOrNull
            ?: throw IllegalArgumentException("globalID 缺少 remoteID")
        return GlobalId(ServerId(server), remote)
    }

    /** trackGIDs 数组条目：对象 {serverID,remoteID} 或 "server:remote" 字符串。 */
    private fun Map<String, JsonElement>.globalIdList(key: String): List<GlobalId> {
        val array = this[key]?.jsonArray ?: return emptyList()
        return array.map { el ->
            val obj = el.jsonObject
            val server = obj["serverID"]?.jsonPrimitive?.contentOrNull
                ?: obj["serverId"]?.jsonPrimitive?.contentOrNull
            val remote = obj["remoteID"]?.jsonPrimitive?.contentOrNull
                ?: obj["remoteId"]?.jsonPrimitive?.contentOrNull
            if (server != null && remote != null) {
                GlobalId(ServerId(server), remote)
            } else {
                GlobalId.parse(el.jsonPrimitive.content)
            }
        }
    }

    private fun intList(key: String, args: Map<String, JsonElement>): List<Int> =
        args[key]?.jsonArray?.mapNotNull { it.jsonPrimitive.contentOrNull?.toIntOrNull() } ?: emptyList()

    // ------------------------------------------------------------------
    // 汇总 JSON（结构化回灌给模型）
    // ------------------------------------------------------------------

    private fun trackSummaries(tracks: List<Track>, limit: Int): JsonObject = buildJsonObject {
        put("count", tracks.size)
        putJsonArray("items") {
            tracks.take(limit).forEach { t ->
                addJsonObject {
                    put("title", t.title)
                    put("artist", t.artistName)
                    put("album", t.albumTitle)
                    put("durationSeconds", t.durationSeconds)
                    putJsonObject("globalID") {
                        put("serverID", t.serverId.value)
                        put("remoteID", t.id.value)
                    }
                }
            }
        }
        if (tracks.size > limit) put("truncated", true)
    }

    private fun albumSummaries(albums: List<Album>, limit: Int): JsonObject = buildJsonObject {
        put("count", albums.size)
        putJsonArray("items") {
            albums.take(limit).forEach { a ->
                addJsonObject {
                    put("title", a.title)
                    put("artist", a.artistName)
                    put("year", a.year ?: 0)
                    putJsonObject("globalID") {
                        put("serverID", a.serverId.value)
                        put("remoteID", a.id.value)
                    }
                }
            }
        }
    }

    private fun artistSummaries(artists: List<Artist>, limit: Int): JsonObject = buildJsonObject {
        put("count", artists.size)
        putJsonArray("items") {
            artists.take(limit).forEach { a ->
                addJsonObject {
                    put("name", a.name)
                    put("albumCount", a.albumCount)
                    putJsonObject("globalID") {
                        put("serverID", a.serverId.value)
                        put("remoteID", a.id.value)
                    }
                }
            }
        }
    }

    private fun playlistSummaries(playlists: List<Playlist>, limit: Int): JsonObject = buildJsonObject {
        put("count", playlists.size)
        putJsonArray("items") {
            playlists.take(limit).forEach { p ->
                addJsonObject {
                    put("name", p.name)
                    put("trackCount", p.trackIds.size)
                    putJsonObject("globalID") {
                        put("serverID", p.serverId.value)
                        put("remoteID", p.id.value)
                    }
                }
            }
        }
    }

    // ------------------------------------------------------------------
    // 工具注册
    // ------------------------------------------------------------------

    fun registerTools() {
        // ================= ReadOnly =================
        ro("capabilities_get", "返回当前可调用的全部工具及其用途分类。", emptyParams()) { _ ->
            buildJsonObject {
                putJsonArray("tools") {
                    registry.descriptors().forEach { d ->
                        addJsonObject {
                            put("name", d.name)
                            put("description", d.description)
                            put("sideEffect", d.sideEffect.name)
                        }
                    }
                }
            }.toString()
        }

        ro("tool_search", "按关键词在工具目录中查找可用工具（含完整参数说明）。", """{"properties":{"query":{"type":"string","description":"关键词"}},"required":["query"],"type":"object"}""") { args ->
            val query = args.string("query") ?: ""
            buildJsonObject {
                putJsonArray("matches") {
                    registry.descriptors()
                        .filter { query.isBlank() || it.name.contains(query, true) || it.description.contains(query, true) }
                        .take(20)
                        .forEach { d ->
                            addJsonObject {
                                put("name", d.name)
                                put("description", d.description)
                            }
                        }
                }
            }.toString()
        }

        ro("searchTracks", "在本地音乐库中按名称搜索歌曲（返回结构化列表；无结果显示，可再用 server_search 在线搜索）。", """{"properties":{"q":{"type":"string"},"limit":{"type":"integer"}},"required":["q"],"type":"object"}""") { args ->
            val q = args.string("q") ?: ""
            val limit = args.int("limit")?.coerceIn(1, 50) ?: 20
            val results = graph.catalogRepository.search(activeServerId(), q, limit.coerceAtLeast(20))
            buildJsonObject {
                put("ok", true)
                put("kind", "searchTracks")
                put("query", q)
                put("tracks", trackSummaries(results.songs, limit))
                if (results.songs.isEmpty()) put("hint", "本地目录无匹配；可调用 server_search 到服务器在线搜索")
            }.toString()
        }

        ro("searchAlbums", "在本地音乐库中按名称搜索专辑（返回结构化列表）。", """{"properties":{"q":{"type":"string"},"limit":{"type":"integer"}},"required":["q"],"type":"object"}""") { args ->
            val q = args.string("q") ?: ""
            val limit = args.int("limit")?.coerceIn(1, 30) ?: 15
            val results = graph.catalogRepository.search(activeServerId(), q, limit.coerceAtLeast(20))
            buildJsonObject {
                put("ok", true)
                put("kind", "searchAlbums")
                put("query", q)
                put("albums", albumSummaries(results.albums, limit))
            }.toString()
        }

        ro("searchArtists", "在本地音乐库中按名称搜索艺人（返回结构化列表）。", """{"properties":{"q":{"type":"string"},"limit":{"type":"integer"}},"required":["q"],"type":"object"}""") { args ->
            val q = args.string("q") ?: ""
            val limit = args.int("limit")?.coerceIn(1, 30) ?: 15
            val results = graph.catalogRepository.search(activeServerId(), q, limit.coerceAtLeast(20))
            buildJsonObject {
                put("ok", true)
                put("kind", "searchArtists")
                put("query", q)
                put("artists", artistSummaries(results.artists, limit))
            }.toString()
        }

        ro("getTrack", "按全局 ID 查询单首歌曲的完整元数据。", """{"properties":{"globalID":{"type":"object"}},"required":["globalID"],"type":"object"}""") { args ->
            val gid = args.globalId()
            val t = graph.catalogRepository.track(gid)
                ?: throw IllegalArgumentException("本地目录中找不到该歌曲（可能未同步该服务器）")
            buildJsonObject {
                put("ok", true)
                put("track", trackSummaries(listOf(t), 1)["items"]?.jsonArray?.first()?.jsonObject
                    ?: buildJsonObject { })
                put("isFavorite", t.isFavorite)
                put("rating", t.rating ?: 0)
            }.toString()
        }

        ro("getAlbum", "按全局 ID 查询专辑与曲目。", """{"properties":{"globalID":{"type":"object"}},"required":["globalID"],"type":"object"}""") { args ->
            val gid = args.globalId()
            val album = graph.catalogRepository.album(gid)
                ?: throw IllegalArgumentException("本地目录中找不到该专辑")
            val tracks = graph.catalogRepository.albumTracks(album.globalId)
            buildJsonObject {
                put("ok", true)
                put("title", album.title)
                put("artist", album.artistName)
                put("albumTracks", trackSummaries(tracks, 200))
            }.toString()
        }

        ro("getArtist", "按全局 ID 查询艺人及其主要专辑。", """{"properties":{"globalID":{"type":"object"}},"required":["globalID"],"type":"object"}""") { args ->
            val gid = args.globalId()
            val artist = graph.catalogRepository.artist(gid)
                ?: throw IllegalArgumentException("本地目录中找不到该艺人")
            val albums = graph.catalogRepository.artistAlbums(artist.globalId)
            val tracks = graph.catalogRepository.artistTracks(artist.globalId)
            buildJsonObject {
                put("ok", true)
                put("name", artist.name)
                put("albums", albumSummaries(albums, 50))
                put("topTracks", trackSummaries(tracks, 20))
            }.toString()
        }

        ro("listPlaylists", "列出所有歌单。", emptyParams()) {
            val serverId = activeServerId()
            val all = graph.catalogRepository.observePlaylists(serverId).first()
            buildJsonObject {
                put("ok", true)
                put("playlists", playlistSummaries(all, 100))
            }.toString()
        }

        ro("getPlaylist", "按全局 ID 查询歌单详情与曲目。", """{"properties":{"globalID":{"type":"object"}},"required":["globalID"],"type":"object"}""") { args ->
            val gid = args.globalId()
            val playlist = graph.catalogRepository.playlist(gid)
                ?: throw IllegalArgumentException("找不到该歌单")
            val tracks = graph.catalogRepository.playlistTracks(playlist.globalId)
            buildJsonObject {
                put("ok", true)
                put("name", playlist.name)
                put("playlistTracks", trackSummaries(tracks, 300))
            }.toString()
        }

        ro("getFavorites", "列出收藏的歌曲。", """{"properties":{"limit":{"type":"integer"}},"type":"object"}""") { args ->
            val limit = args.int("limit")?.coerceIn(1, 100) ?: 50
            val tracks = graph.catalogRepository.favoriteTracks(activeServerId())
            buildJsonObject {
                put("ok", true)
                put("tracks", trackSummaries(tracks, limit))
            }.toString()
        }

        ro("getCurrentTrack", "返回当前正在播放的歌曲。", emptyParams()) {
            val snapshot = LocalPlaybackHost.controller().playback.value
            if (snapshot.track == null) {
                buildJsonObject { put("ok", false); put("message", "当前没有播放内容") }.toString()
            } else {
                buildJsonObject {
                    put("ok", true)
                    put("currentTrack", trackSummaries(listOf(snapshot.track!!), 1)["items"]!!.jsonArray.first().jsonObject)
                    put("positionSeconds", snapshot.positionMs / 1000)
                    put("isPlaying", snapshot.state is com.auralis.core.domain.PlaybackState.Playing)
                }.toString()
            }
        }

        ro("getCurrentQueue", "返回当前播放队列（entryID 用于 queue_remove）。", emptyParams()) {
            val queue = LocalPlaybackHost.controller().queue.value
            buildJsonObject {
                put("ok", true)
                put("count", queue.entries.size)
                put("totalCount", queue.totalCount)
                putJsonArray("entries") {
                    queue.entries.forEach { e ->
                        addJsonObject {
                            put("entryID", e.id.value)
                            put("title", e.track.title)
                            put("artist", e.track.artistName)
                            putJsonObject("globalID") {
                                put("serverID", e.track.serverId.value)
                                put("remoteID", e.track.id.value)
                            }
                        }
                    }
                }
            }.toString()
        }

        // ---- R4：「由此继续播放」链路（对齐 Swift AgentToolkit 同名工具）----

        ro("library_get_similar_songs", "以指定歌曲为种子，从服务器查找相似歌曲（OpenSubsonic getSimilarSongs2），去重并排除不喜欢的曲目，供生成相似队列。", """{"properties":{"globalID":{"type":"object","description":"种子歌曲"},"count":{"type":"integer","description":"期望返回数量，默认 20"}},"required":["globalID"],"type":"object"}""") { args ->
            val gid = args.globalId()
            val seed = graph.catalogRepository.track(gid)
                ?: throw IllegalArgumentException("本地目录中找不到种子歌曲（可能未同步该服务器）")
            val target = args.int("count")?.coerceIn(1, 60) ?: 20
            val disliked = graph.catalogRepository.dislikedIds(gid.serverId)
            val similar = graph.similarSongs(gid.serverId, gid.remoteId, count = 60)
                .filter { it.globalId != gid && it.globalId !in disliked }
                .distinctBy { it.id.value }
                .take(target)
            buildJsonObject {
                put("ok", true)
                put("seed", "${seed.title} — ${seed.artistName}")
                put("requested", target)
                put("returned", similar.size)
                put("tracks", trackSummaries(similar, target))
                if (similar.isEmpty()) put("hint", "服务器没有返回相似歌曲；可改用 searchTracks/playAlbum 兜底")
            }.toString()
        }

        write("queue_replace", "用给定歌曲列表替换当前播放队列并开始播放（只调用一次即完成整个替换；列表顺序即播放顺序）。", """{"properties":{"globalIDs":{"type":"array","items":{"type":"object"},"description":"目标队列歌曲 globalID（顺序即播放顺序）"},"startIndex":{"type":"integer","description":"从第几首开始播放，默认 0"}},"required":["globalIDs"],"type":"object"}""") { args ->
            val gids = args.globalIdList("globalIDs")
            if (gids.isEmpty()) throw IllegalArgumentException("globalIDs 不能为空")
            val tracks = gids.map { gid ->
                graph.catalogRepository.track(gid)
                    ?: throw IllegalArgumentException("本地目录中找不到 ${gid.serialized}（可能未同步该服务器）")
            }
            val controller = requireEngine()
            val start = (args.int("startIndex") ?: 0).coerceIn(0, tracks.lastIndex)
            controller.playQueue(tracks.map { QueueEntry.of(it) }, start)
            "已替换播放队列：共 ${tracks.size} 首，从《${tracks[start].title}》开始播放。"
        }

        ro("server_list", "列出已连接的服务器。", emptyParams()) {
            val servers = graph.catalogRepository.servers()
            val activeId = activeServerId()?.value
            buildJsonObject {
                put("ok", true)
                putJsonArray("servers") {
                    servers.forEach { s ->
                        addJsonObject {
                            put("name", s.displayName)
                            put("serverID", s.id.value)
                            put("active", s.id.value == activeId)
                        }
                    }
                }
            }.toString()
        }

        ro("server_search", "在服务器在线搜索歌曲（OpenSubsonic search3，仅返回歌曲；本地无结果时作为兜底）。", """{"properties":{"q":{"type":"string"},"serverID":{"type":"string"},"limit":{"type":"integer"}},"required":["q"],"type":"object"}""") { args ->
            val q = args.string("q") ?: throw IllegalArgumentException("缺少 q")
            val serverId = args.string("serverID")?.let { ServerId(it) } ?: activeServerId()
                ?: throw IllegalArgumentException("没有已连接的服务器")
            val limit = args.int("limit")?.coerceIn(1, 50) ?: 15
            val tracks = graph.serverSearch(serverId, q, limit)
            buildJsonObject {
                put("ok", true)
                put("kind", "server_search")
                put("query", q)
                put("tracks", trackSummaries(tracks, limit))
            }.toString()
        }

        ro("lyrics_get", "获取某首歌曲的歌词。", """{"properties":{"globalID":{"type":"object"}},"required":["globalID"],"type":"object"}""") { args ->
            val gid = args.globalId()
            val track = graph.catalogRepository.track(gid)
                ?: throw IllegalArgumentException("本地目录中找不到该歌曲")
            val doc = graph.lyricsService.lyricsFor(track)
            if (doc == null || doc.lines.isEmpty()) {
                buildJsonObject { put("ok", false); put("message", "没有可用歌词") }.toString()
            } else {
                buildJsonObject {
                    put("ok", true)
                    put("synced", doc.isSynced)
                    put("language", doc.language ?: "")
                    put("lineCount", doc.lines.size)
                    putJsonArray("preview") {
                        doc.lines.take(6).forEach { l -> addJsonObject { put("text", l.text) } }
                    }
                }.toString()
            }
        }

        ro("library_get_summary", "返回本地音乐库概况（歌曲/专辑/艺人/歌单数量）。", emptyParams()) {
            val serverId = activeServerId()
            val stats = serverId?.let { runCatching { graph.catalogRepository.stats(it) }.getOrNull() }
            buildJsonObject {
                put("ok", true)
                put("serverConnected", serverId != null)
                if (stats != null) {
                    put("trackCount", stats.trackCount)
                    put("albumCount", stats.albumCount)
                    put("artistCount", stats.artistCount)
                    put("playlistCount", stats.playlistCount)
                }
            }.toString()
        }

        // ================= Write（reversible；授权由 consent 门控制） =================

        write("playTrack", "立即播放指定歌曲。", """{"properties":{"globalID":{"type":"object"}},"required":["globalID"],"type":"object"}""") { args ->
            val gid = args.globalId()
            val track = graph.catalogRepository.track(gid)
                ?: throw IllegalArgumentException("本地目录中找不到该歌曲")
            val controller = requireEngine()
            controller.playQueue(listOf(QueueEntry.of(track)), 0)
            "已开始播放《${track.title}》- ${track.artistName}"
        }

        write("playAlbum", "按顺序播放整个专辑。", """{"properties":{"globalID":{"type":"object"}},"required":["globalID"],"type":"object"}""") { args ->
            val gid = args.globalId()
            val album = graph.catalogRepository.album(gid)
                ?: throw IllegalArgumentException("本地目录中找不到该专辑")
            val tracks = graph.catalogRepository.albumTracks(album.globalId)
            if (tracks.isEmpty()) throw IllegalArgumentException("专辑没有可播放的曲目")
            val controller = requireEngine()
            controller.playQueue(tracks.map { QueueEntry.of(it) }, 0)
            "已开始播放专辑《${album.title}》- ${album.artistName}（${tracks.size} 首）"
        }

        write("playPlaylist", "播放整个歌单。", """{"properties":{"globalID":{"type":"object"}},"required":["globalID"],"type":"object"}""") { args ->
            val gid = args.globalId()
            val playlist = graph.catalogRepository.playlist(gid)
                ?: throw IllegalArgumentException("找不到该歌单")
            val tracks = graph.catalogRepository.playlistTracks(playlist.globalId)
            if (tracks.isEmpty()) throw IllegalArgumentException("歌单没有可播放的曲目")
            val controller = requireEngine()
            controller.playQueue(tracks.map { QueueEntry.of(it) }, 0)
            "已开始播放歌单「${playlist.name}」（${tracks.size} 首）"
        }

        write("addToQueue", "把歌曲追加到播放队列末尾（不打断当前播放）。", """{"properties":{"globalID":{"type":"object"}},"required":["globalID"],"type":"object"}""") { args ->
            val gid = args.globalId()
            val track = graph.catalogRepository.track(gid)
                ?: throw IllegalArgumentException("本地目录中找不到该歌曲")
            val controller = requireEngine()
            controller.appendToQueue(listOf(QueueEntry.of(track)))
            "已把《${track.title}》加入队列"
        }

        write("playNext", "把歌曲插到当前播放之后（下一首播放）。", """{"properties":{"globalID":{"type":"object"}},"required":["globalID"],"type":"object"}""") { args ->
            val gid = args.globalId()
            val track = graph.catalogRepository.track(gid)
                ?: throw IllegalArgumentException("本地目录中找不到该歌曲")
            val controller = requireEngine()
            controller.insertNext(listOf(QueueEntry.of(track)))
            "已把《${track.title}》设为下一首播放"
        }

        write("pause", "暂停当前播放。", emptyParams()) {
            val controller = requireEngine()
            val state = controller.playback.value
            if (state.entry == null) throw IllegalArgumentException("当前没有播放内容")
            if (state.state is com.auralis.core.domain.PlaybackState.Paused) "当前已处于暂停状态" else { controller.pause(); "已暂停" }
        }

        write("resume", "继续播放。", emptyParams()) {
            val controller = requireEngine()
            val state = controller.playback.value
            if (state.entry == null) throw IllegalArgumentException("当前没有播放内容")
            if (state.state is com.auralis.core.domain.PlaybackState.Playing) "当前已在播放" else { controller.togglePlayPause(); "已继续播放" }
        }

        write("seek", "跳转到指定秒数。", """{"properties":{"positionSeconds":{"type":"number"}},"required":["positionSeconds"],"type":"object"}""") { args ->
            val seconds = args.double("positionSeconds") ?: throw IllegalArgumentException("缺少 positionSeconds")
            val controller = requireEngine()
            val snapshot = controller.playback.value
            if (snapshot.entry == null) throw IllegalArgumentException("当前没有播放内容")
            controller.seekTo((seconds * 1000).toLong())
            "已跳转到 ${seconds} 秒"
        }

        write("next", "播放下一首。", emptyParams()) {
            val controller = requireEngine()
            if (controller.queue.value.entries.isEmpty()) throw IllegalArgumentException("队列为空")
            controller.next()
            "已切到下一首"
        }

        write("previous", "播放上一首。", emptyParams()) {
            val controller = requireEngine()
            if (controller.queue.value.entries.isEmpty()) throw IllegalArgumentException("队列为空")
            controller.previous()
            "已切到上一首"
        }

        write("likeTrack", "收藏指定歌曲。", """{"properties":{"globalID":{"type":"object"}},"required":["globalID"],"type":"object"}""") { args ->
            val gid = args.globalId()
            val track = graph.catalogRepository.track(gid)
                ?: throw IllegalArgumentException("本地目录中找不到该歌曲")
            val already = graph.catalogRepository.isFavorite(track.globalId, FavoriteKind.Track)
            if (already) "《${track.title}》已在收藏中" else {
                graph.libraryActions.setTrackFavorite(track, true)
                "已收藏《${track.title}》"
            }
        }

        write("unlikeTrack", "取消收藏指定歌曲。", """{"properties":{"globalID":{"type":"object"}},"required":["globalID"],"type":"object"}""") { args ->
            val gid = args.globalId()
            val track = graph.catalogRepository.track(gid)
                ?: throw IllegalArgumentException("本地目录中找不到该歌曲")
            val already = graph.catalogRepository.isFavorite(track.globalId, FavoriteKind.Track)
            if (!already) "《${track.title}》本就不在收藏中" else {
                graph.libraryActions.setTrackFavorite(track, false)
                "已取消收藏《${track.title}》"
            }
        }

        write("favoriteAlbum", "收藏指定专辑。", """{"properties":{"globalID":{"type":"object"}},"required":["globalID"],"type":"object"}""") { args ->
            val gid = args.globalId()
            val album = graph.catalogRepository.album(gid)
                ?: throw IllegalArgumentException("本地目录中找不到该专辑")
            val already = graph.catalogRepository.isFavorite(album.globalId, FavoriteKind.Album)
            if (already) "专辑《${album.title}》已在收藏中" else {
                val ok = graph.libraryActions.toggleAlbumFavorite(album)
                if (!ok) throw IllegalArgumentException("服务器操作失败，请稍后重试")
                "已收藏专辑《${album.title}》"
            }
        }

        write("unfavoriteAlbum", "取消收藏指定专辑。", """{"properties":{"globalID":{"type":"object"}},"required":["globalID"],"type":"object"}""") { args ->
            val gid = args.globalId()
            val album = graph.catalogRepository.album(gid)
                ?: throw IllegalArgumentException("本地目录中找不到该专辑")
            val already = graph.catalogRepository.isFavorite(album.globalId, FavoriteKind.Album)
            if (!already) "专辑《${album.title}》本就不在收藏中" else {
                val ok = graph.libraryActions.toggleAlbumFavorite(album)
                if (!ok) throw IllegalArgumentException("服务器操作失败，请稍后重试")
                "已取消收藏专辑《${album.title}》"
            }
        }

        write("setRating", "给歌曲评分（1-5 星）。", """{"properties":{"globalID":{"type":"object"},"rating":{"type":"integer"}},"required":["globalID","rating"],"type":"object"}""") { args ->
            val gid = args.globalId()
            val rating = args.int("rating") ?: throw IllegalArgumentException("缺少 rating")
            if (rating !in 1..5) throw IllegalArgumentException("rating 必须在 1-5")
            val track = graph.catalogRepository.track(gid)
                ?: throw IllegalArgumentException("本地目录中找不到该歌曲")
            graph.libraryActions.setRating(track, rating)
            "已把《${track.title}》评为 $rating 星"
        }

        write("clearRating", "清除歌曲评分。", """{"properties":{"globalID":{"type":"object"}},"required":["globalID"],"type":"object"}""") { args ->
            val gid = args.globalId()
            val track = graph.catalogRepository.track(gid)
                ?: throw IllegalArgumentException("本地目录中找不到该歌曲")
            graph.libraryActions.setRating(track, null)
            "已清除《${track.title}》的评分"
        }

        write("createPlaylist", "新建歌单。", """{"properties":{"name":{"type":"string"},"serverID":{"type":"string"}},"required":["name"],"type":"object"}""") { args ->
            val name = args.string("name") ?: throw IllegalArgumentException("缺少 name")
            val serverId = args.string("serverID")?.let { ServerId(it) } ?: activeServerId()
                ?: throw IllegalArgumentException("没有已连接的服务器，无法创建歌单")
            val created = graph.playlistActions.createPlaylist(name.trim(), serverId)
                ?: throw IllegalArgumentException("服务器创建歌单失败")
            "已创建歌单「${created.name}」"
        }

        write("renamePlaylist", "重命名歌单。", """{"properties":{"playlistGID":{"type":"object"},"name":{"type":"string"}},"required":["playlistGID","name"],"type":"object"}""") { args ->
            val gid = args.globalId("playlistGID")
            val name = args.string("name") ?: throw IllegalArgumentException("缺少 name")
            val playlist = graph.catalogRepository.playlist(gid)
                ?: throw IllegalArgumentException("找不到该歌单")
            val ok = graph.playlistActions.rename(playlist, name.trim())
            if (!ok) throw IllegalArgumentException("服务器重命名失败")
            "已重命名为「${name.trim()}」"
        }

        write("addTracksToPlaylist", "把歌曲加入歌单。", """{"properties":{"playlistGID":{"type":"object"},"trackGIDs":{"type":"array","items":{"type":"object"}}},"required":["playlistGID","trackGIDs"],"type":"object"}""") { args ->
            val gid = args.globalId("playlistGID")
            val trackGids = args.globalIdList("trackGIDs")
            if (trackGids.isEmpty()) throw IllegalArgumentException("trackGIDs 为空")
            val playlist = graph.catalogRepository.playlist(gid)
                ?: throw IllegalArgumentException("找不到该歌单")
            val tracks = trackGids.map { t ->
                val track = graph.catalogRepository.track(t)
                    ?: throw IllegalArgumentException("找不到歌曲 ${t.serialized}（未同步？）")
                if (track.serverId.value != playlist.serverId.value) {
                    throw IllegalArgumentException("歌曲与歌单不在同一服务器，已拒绝执行")
                }
                track
            }
            val ok = graph.playlistActions.addTracks(playlist, tracks)
            if (!ok) throw IllegalArgumentException("服务器添加失败")
            "已把 ${tracks.size} 首歌曲加入歌单「${playlist.name}」"
        }

        write("removeTracksFromPlaylist", "从歌单移除指定下标的歌曲（indices 从 0 开始）。", """{"properties":{"playlistGID":{"type":"object"},"indices":{"type":"array","items":{"type":"integer"}}},"required":["playlistGID","indices"],"type":"object"}""") { args ->
            val gid = args.globalId("playlistGID")
            val indices = intList("indices", args).distinct().sorted()
            if (indices.isEmpty()) throw IllegalArgumentException("indices 为空")
            val playlist = graph.catalogRepository.playlist(gid)
                ?: throw IllegalArgumentException("找不到该歌单")
            val ok = graph.playlistActions.removeAt(playlist, indices)
            if (!ok) throw IllegalArgumentException("服务器移除失败")
            "已从歌单移除 ${indices.size} 首歌曲"
        }

        write("queue_remove", "从播放队列移除指定条目（entryID 见 getCurrentQueue）。", """{"properties":{"entryID":{"type":"string"}},"required":["entryID"],"type":"object"}""") { args ->
            val entryId = args.string("entryID") ?: throw IllegalArgumentException("缺少 entryID")
            val controller = requireEngine()
            controller.removeOccurrence(QueueEntryId(entryId))
            "已从队列移除该条目"
        }

        write("queue_save_as_playlist", "把当前播放队列存为歌单。", """{"properties":{"name":{"type":"string"}},"required":["name"],"type":"object"}""") { args ->
            val name = args.string("name") ?: throw IllegalArgumentException("缺少 name")
            val serverId = activeServerId() ?: throw IllegalArgumentException("没有已连接的服务器")
            val queue = LocalPlaybackHost.controller().queue.value
            val tracks = queue.entries.map { it.track }
            if (tracks.isEmpty()) throw IllegalArgumentException("播放队列为空")
            if (tracks.any { it.serverId.value != serverId.value }) {
                throw IllegalArgumentException("队列混有多个服务器内容，无法整单保存，已拒绝执行")
            }
            val created = graph.playlistActions.createPlaylist(name.trim(), serverId, tracks.map { it.id.value })
                ?: throw IllegalArgumentException("服务器创建歌单失败")
            "已把当前队列（${tracks.size} 首）存为歌单「${created.name}」"
        }

        // ================= Destructive（逐次确认，绑定 runID） =================

        destructive("deletePlaylist", "永久删除歌单（不可恢复）。", """{"properties":{"playlistGID":{"type":"object"}},"required":["playlistGID"],"type":"object"}""") { args ->
            val gid = args.globalId("playlistGID")
            val playlist = graph.catalogRepository.playlist(gid)
                ?: throw IllegalArgumentException("找不到该歌单")
            val ok = graph.playlistActions.delete(playlist)
            if (!ok) throw IllegalArgumentException("服务器删除失败")
            "已删除歌单「${playlist.name}」"
        }
    }

    // ------------------------------------------------------------------

    fun registry(): AgentToolRegistry = registry

    /** 操作日志「撤销」：执行逆向工具（仅当该记录可逆；写操作由用户点击触发，视为授权）。 */
    suspend fun undo(record: AssistantActionRecord): String {
        val inverse = INVERSE_TOOL[record.operation]
            ?: throw IllegalArgumentException("该操作不支持撤销")
        val args = kotlinx.serialization.json.Json.parseToJsonElement(record.argumentsJson).jsonObject
        val authorization = SideEffectAuthorizationContext(setOf(inverse))
        return registry.execute(inverse, args, authorization) { true }
    }

    companion object {
        /** 可逆映射：撤销 = 以相同参数执行逆向工具。 */
        val INVERSE_TOOL: Map<String, String> = mapOf(
            "likeTrack" to "unlikeTrack",
            "unlikeTrack" to "likeTrack",
            "favoriteAlbum" to "unfavoriteAlbum",
            "unfavoriteAlbum" to "favoriteAlbum",
        )

        /** 工具显示名（UI 工具行标签）。 */
        fun toolLabel(name: String): String = when (name) {
            "playTrack" -> "播放歌曲"
            "playAlbum" -> "播放专辑"
            "playPlaylist" -> "播放歌单"
            "addToQueue" -> "加入队列"
            "playNext" -> "下一首播放"
            "pause" -> "暂停"
            "resume" -> "继续播放"
            "seek" -> "跳转进度"
            "next" -> "下一首"
            "previous" -> "上一首"
            "likeTrack" -> "收藏歌曲"
            "unlikeTrack" -> "取消收藏"
            "favoriteAlbum" -> "收藏专辑"
            "unfavoriteAlbum" -> "取消收藏专辑"
            "setRating" -> "评分"
            "clearRating" -> "清除评分"
            "createPlaylist" -> "新建歌单"
            "renamePlaylist" -> "重命名歌单"
            "addTracksToPlaylist" -> "加入歌单"
            "removeTracksFromPlaylist" -> "移除歌单歌曲"
            "deletePlaylist" -> "删除歌单"
            "queue_remove" -> "移除队列条目"
            "queue_save_as_playlist" -> "队列存为歌单"
            "library_get_similar_songs" -> "查找相似歌曲"
            "queue_replace" -> "替换播放队列"
            "server_search" -> "在线搜索"
            "searchTracks" -> "搜索歌曲"
            "searchAlbums" -> "搜索专辑"
            "searchArtists" -> "搜索艺人"
            "lyrics_get" -> "获取歌词"
            "getCurrentQueue" -> "查看队列"
            else -> name
        }
    }

    // ------------------------------------------------------------ 注册辅助

    private fun emptyParams(): String? = """{"type":"object","properties":{}}"""

    private fun ro(
        name: String,
        description: String,
        parametersJson: String?,
        executor: suspend (Map<String, JsonElement>) -> String,
    ) {
        registry.register(
            AgentToolDescriptor(name, description, parametersJson, ToolSideEffect.ReadOnly),
            executor,
        )
    }

    private fun write(
        name: String,
        description: String,
        parametersJson: String?,
        executor: suspend (Map<String, JsonElement>) -> String,
    ) {
        registry.register(
            AgentToolDescriptor(name, description, parametersJson, ToolSideEffect.Write, ToolConfirmationPolicy.None),
            executor,
        )
    }

    private fun destructive(
        name: String,
        description: String,
        parametersJson: String?,
        executor: suspend (Map<String, JsonElement>) -> String,
    ) {
        registry.register(
            AgentToolDescriptor(name, description, parametersJson, ToolSideEffect.Write, ToolConfirmationPolicy.Destructive),
            executor,
        )
    }
}
