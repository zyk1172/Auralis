// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.core.playback

import android.content.Context
import com.auralis.core.domain.PlayMode
import com.auralis.core.domain.QueueEntry
import com.auralis.core.domain.QueueEntryId
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.filter
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withTimeout

interface PlaybackController {
    val playback: StateFlow<PlaybackSnapshot>
    val queue: StateFlow<QueueSnapshot>
    val position: StateFlow<Long>

    suspend fun playQueue(entries: List<QueueEntry>, startLogicalIndex: Int = 0, startAtMs: Long = 0)
    suspend fun playOccurrence(entryId: QueueEntryId)
    suspend fun playAtLogicalIndex(index: Int)
    fun togglePlayPause()
    fun pause()
    fun seekTo(positionMs: Long)
    fun next()
    fun previous()
    fun cyclePlayMode()
    fun setPlayMode(mode: PlayMode)
    fun setSpeed(speed: Float)
    fun setVolume(volume: Float)
    fun configureReplayGain(settings: com.auralis.core.domain.ReplayGainSettings)
    fun removeOccurrence(entryId: QueueEntryId)
    fun moveOccurrence(entryId: QueueEntryId, toLogicalIndex: Int)

    fun insertNext(entries: List<QueueEntry>)
    fun appendToQueue(entries: List<QueueEntry>)

    /** Remove only occurrences after the current item; current playback remains untouched. */
    fun clearUpcoming()

    fun clearQueue()
    fun release()
}

suspend fun awaitPlaybackController(
    startService: () -> Unit,
    timeoutMs: Long = 8_000,
): PlaybackController {
    if (!LocalPlaybackHost.available.value) {
        startService()
        awaitAvailableFlow(LocalPlaybackHost.available, timeoutMs)
    }
    return LocalPlaybackHost.controller()
}

internal suspend fun awaitAvailableFlow(available: StateFlow<Boolean>, timeoutMs: Long) {
    withTimeout(timeoutMs) {
        available.filter { it }.first()
    }
}

object LocalPlaybackHost {
    private val _available = MutableStateFlow(false)
    val available: StateFlow<Boolean> = _available.asStateFlow()

    @Volatile
    internal var engine: AuralisPlaybackEngine? = null
        set(value) {
            field = value
            _available.value = value != null
        }

    fun controller(): PlaybackController = EnginePlaybackController { engine }

    internal fun clear() {
        engine = null
    }
}

private class EnginePlaybackController(
    private val engineProvider: () -> AuralisPlaybackEngine?,
) : PlaybackController {
    private fun requireEngine(): AuralisPlaybackEngine =
        engineProvider() ?: error("Auralis 播放引擎未就绪：请先启动 AuralisPlaybackService")

    override val playback: StateFlow<PlaybackSnapshot>
        get() = requireEngine().playback
    override val queue: StateFlow<QueueSnapshot>
        get() = requireEngine().queue
    override val position: StateFlow<Long>
        get() = requireEngine().position

    override suspend fun playQueue(entries: List<QueueEntry>, startLogicalIndex: Int, startAtMs: Long) =
        requireEngine().playQueue(entries, startLogicalIndex, startAtMs)

    override suspend fun playOccurrence(entryId: QueueEntryId) = requireEngine().playOccurrence(entryId)
    override suspend fun playAtLogicalIndex(index: Int) = requireEngine().playAtLogicalIndex(index)
    override fun togglePlayPause() = requireEngine().togglePlayPause()
    override fun pause() = requireEngine().pause()
    override fun seekTo(positionMs: Long) = requireEngine().seekTo(positionMs)
    override fun next() = requireEngine().next()
    override fun previous() = requireEngine().previous()
    override fun cyclePlayMode() = requireEngine().cyclePlayMode()
    override fun setPlayMode(mode: PlayMode) = requireEngine().setPlayMode(mode)
    override fun setSpeed(speed: Float) = requireEngine().setSpeed(speed)
    override fun setVolume(volume: Float) = requireEngine().setVolume(volume)
    override fun configureReplayGain(settings: com.auralis.core.domain.ReplayGainSettings) =
        requireEngine().configureReplayGain(settings)
    override fun removeOccurrence(entryId: QueueEntryId) = requireEngine().removeOccurrence(entryId)
    override fun moveOccurrence(entryId: QueueEntryId, toLogicalIndex: Int) =
        requireEngine().moveOccurrence(entryId, toLogicalIndex)
    override fun insertNext(entries: List<QueueEntry>) = requireEngine().insertNext(entries)
    override fun appendToQueue(entries: List<QueueEntry>) = requireEngine().appendToQueue(entries)
    override fun clearUpcoming() = requireEngine().clearUpcoming()
    override fun clearQueue() = requireEngine().clearQueue()

    override fun release() {
        LocalPlaybackHost.clear()
    }
}

internal object PlaybackEngineFactory {
    fun create(
        context: Context,
        resolver: com.auralis.core.domain.PlaybackSourceResolver,
        historySink: PlaybackHistorySink?,
    ): AuralisPlaybackEngine {
        val appContext = context.applicationContext
        val okHttp = okhttp3.OkHttpClient.Builder()
            .connectTimeout(30, java.util.concurrent.TimeUnit.SECONDS)
            .readTimeout(60, java.util.concurrent.TimeUnit.SECONDS)
            .build()
        return AuralisPlaybackEngine(appContext, resolver, okHttp, historySink)
    }
}
