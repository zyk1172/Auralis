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

/**
 * 播放控制器（UI 侧唯一入口）。
 *
 * Compose → ViewModel → [PlaybackController] → [LocalPlaybackHost.engine] → ExoPlayer。
 * UI **绝不直接持有 ExoPlayer**。系统媒体控制（锁屏/耳机）走 MediaSession →
 * 同一个 Player，因此两条命令路径天然一致。
 */
interface PlaybackController {
    val playback: StateFlow<PlaybackSnapshot>
    val queue: StateFlow<QueueSnapshot>

    /** 约 250ms 一拍的**真实**播放位置（Now Playing 进度条 / 歌词高亮专用）。 */
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

    /** 下一首播放（对齐 Swift `playNext(tracks:)`）：按序插到当前项之后；未播时插队首；不打断当前曲目。 */
    fun insertNext(entries: List<QueueEntry>)

    /** 加入队列（对齐 Swift `appendToQueue`）：追加到队尾；不自动起播、不打断当前播放。 */
    fun appendToQueue(entries: List<QueueEntry>)

    fun clearQueue()

    /** 由播放服务生命周期调用（跨 Activity/页面共享同一引擎）。 */
    fun release()
}

/**
 * P0-1（审查 R1）：获取引擎就绪的 [PlaybackController] —— **统一入口**。
 *
 * 背景：UI 层若写成「引擎未就绪 → startPlaybackService() 并 return」，会把用户第一次
 * 点击的播放意图吞掉（服务刚起、引擎未 ready，用户要再点一次才播）。
 * 本函数保证：任何一次用户操作经 [startService] 启动播放服务后**等待引擎可用**，
 * 再返回 controller 继续执行原意图 —— 第一次点击即对应第一次播放。
 *
 * @param startService 幂等启动 AuralisPlaybackService 的动作（由组合根注入，避免
 *   core:playback 依赖 appContext / core:data）。
 * @param timeoutMs 等待引擎就绪超时（默认 8s）。超时抛 [kotlinx.coroutines.TimeoutCancellationException]，
 *   调用方必须把失败如实反馈给用户（Toast/错误行），不得静默丢弃意图。
 */
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

/**
 * 等待 [available] 变为 true（引擎就绪）。
 * R3：拆出以便纯 JVM 单测覆盖「冷启动等待 → 就绪返回 / 超时抛异常」语义。
 */
internal suspend fun awaitAvailableFlow(available: StateFlow<Boolean>, timeoutMs: Long) {
    withTimeout(timeoutMs) {
        available.filter { it }.first()
    }
}

/**
 * 进程内播放宿主。
 *
 * `AuralisPlaybackService`（MediaSessionService）持有并长期复用同一个引擎；
 * UI 通过 [PlaybackController] 访问它。**不要**在每次切歌/重组时 new ExoPlayer。
 */
object LocalPlaybackHost {
    private val _available = MutableStateFlow(false)

    /** 引擎是否已就绪（服务创建后为 true）。 */
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

    override fun clearQueue() = requireEngine().clearQueue()

    override fun release() {
        // 引擎生命周期由服务管理；此处仅确保进程内引用可清理。
        LocalPlaybackHost.clear()
    }
}

/** 供服务在 `onCreate` 时装配引擎。 */
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
