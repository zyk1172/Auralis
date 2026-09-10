// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.core.playback

import android.content.Context
import com.auralis.core.domain.PlayMode
import com.auralis.core.domain.QueueEntry
import com.auralis.core.domain.QueueEntryId
import com.auralis.core.domain.Track
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

/**
 * A bounded, self-contained playback snapshot used only for process/device resumption.
 *
 * We intentionally persist a small neighborhood around the current occurrence rather than a
 * potentially 10k-track logical queue. This keeps SharedPreferences writes cheap and gives media
 * buttons/SystemUI useful Previous/Next context after process death without storing expiring stream
 * URLs. Each Track is persisted as metadata; URLs are freshly resolved on resumption.
 */
@Serializable
data class PersistedPlaybackSession(
    val entries: List<PersistedPlaybackEntry>,
    val currentIndex: Int,
    val positionMs: Long,
    val playMode: PlayMode,
    val speed: Float,
)

@Serializable
data class PersistedPlaybackEntry(
    val occurrenceId: String,
    val track: Track,
) {
    fun toQueueEntry(): QueueEntry = QueueEntry(QueueEntryId(occurrenceId), track)
}

class PlaybackSessionStore(context: Context) {
    private val prefs = context.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
    private val json = Json { ignoreUnknownKeys = true }

    fun capture(playback: PlaybackSnapshot, queue: QueueSnapshot, positionMs: Long) {
        val currentWindow = queue.currentWindowIndex
        val stableEntries = queue.entries.toList()
        if (playback.track == null || currentWindow == null || stableEntries.isEmpty()) {
            clear()
            return
        }

        val start = (currentWindow - PREVIOUS_CONTEXT).coerceAtLeast(0)
        val endExclusive = (currentWindow + NEXT_CONTEXT + 1).coerceAtMost(stableEntries.size)
        val slice = stableEntries.subList(start, endExclusive)
        if (slice.isEmpty()) {
            clear()
            return
        }

        val snapshot = PersistedPlaybackSession(
            entries = slice.map { PersistedPlaybackEntry(it.id.value, it.track) },
            currentIndex = currentWindow - start,
            positionMs = positionMs.coerceAtLeast(0L),
            playMode = playback.playMode,
            speed = playback.speed,
        )
        prefs.edit().putString(KEY_SESSION, json.encodeToString(snapshot)).apply()
    }

    fun restore(): PersistedPlaybackSession? {
        val raw = prefs.getString(KEY_SESSION, null) ?: return null
        return runCatching { json.decodeFromString<PersistedPlaybackSession>(raw) }
            .getOrNull()
            ?.takeIf { it.entries.isNotEmpty() && it.currentIndex in it.entries.indices }
    }

    fun clear() {
        prefs.edit().remove(KEY_SESSION).apply()
    }

    private companion object {
        const val PREFS_NAME = "auralis_playback_session"
        const val KEY_SESSION = "session_v1"
        const val PREVIOUS_CONTEXT = 8
        const val NEXT_CONTEXT = 22
    }
}
