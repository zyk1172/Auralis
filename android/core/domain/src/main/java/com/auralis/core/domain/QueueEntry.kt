package com.auralis.core.domain

import java.util.UUID

/**
 * 播放队列项（P0 语义）。
 *
 * 歌曲身份（[Track]）与队列项身份（[id]）**必须分离**：
 * 同一首歌可以在队列中出现多次，每一次 occurrence 都是独立队列项
 * （对应 OpenSubsonic `indexBasedQueue`：队列按 index 定位）。
 *
 * 因此：
 * - MediaItem.mediaId = [id].value（**不是** track.id）
 * - 点击第 N 个 occurrence 必须精确播放第 N 个
 * - 上一首/下一首基于 entry id / 逻辑下标，绝不能「找第一个 TrackID」
 */
data class QueueEntry(
    val id: QueueEntryId = QueueEntryId(UUID.randomUUID().toString()),
    val track: Track,
) {
    companion object {
        fun of(track: Track) = QueueEntry(track = track)
    }
}
