package com.auralis.core.lyrics

import com.auralis.core.domain.LyricsDocument
import com.auralis.core.domain.LyricsRepository
import com.auralis.core.domain.Track

/**
 * 歌词加载策略。
 *
 * 顺序对齐 Apple：
 * 1. 本地 Room 缓存命中 → 直接返回（离线可用）；
 * 2. 未命中且有网络 → 调远端 fetcher（getLyricsBySongId → 无结构化结果 →
 *    getLyrics(artist + title) 的编排在 opensubsonic 客户端内完成）；
 * 3. 远端也没有 → 写一条「miss」负缓存，避免每次播放都请求一次。
 *
 * 本类无 UI、无 Android 依赖（纯领域），便于单测。
 */
class LyricsServiceImpl(
    private val store: LyricsRepository,
    private val remote: suspend (Track) -> LyricsDocument?,
) {
    suspend fun lyricsFor(track: Track): LyricsDocument? {
        val cached = store.load(track)
        if (cached != null) return cached
        if (cachedMisses.contains(track.globalId.serialized)) return null
        val fetched = runCatching { remote(track) }.getOrNull()
        if (fetched != null) {
            store.save(fetched)
            return fetched
        }
        cachedMisses.add(track.globalId.serialized)
        return null
    }

    private val cachedMisses = java.util.concurrent.ConcurrentHashMap.newKeySet<String>()

    suspend fun invalidate(track: Track) {
        cachedMisses.remove(track.globalId.serialized)
        store.load(track) // 保持语义：至少尝试读
    }

    /** 清空全部歌词缓存（Room 落盘 + 内存 miss 负缓存），对齐 Swift `clearLyricsCache`。 */
    suspend fun clearCache() {
        cachedMisses.clear()
        store.clearCache()
    }
}
