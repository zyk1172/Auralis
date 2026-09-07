package com.auralis.core.playback

import android.content.Context
import android.net.Uri
import androidx.annotation.OptIn
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.okhttp.OkHttpDataSource
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import com.auralis.core.domain.DownloadRepository
import com.auralis.core.domain.PlayMode
import com.auralis.core.domain.PlaybackError
import com.auralis.core.domain.PlaybackSourceResolver
import com.auralis.core.domain.PlaybackState
import com.auralis.core.domain.QueueEntry
import com.auralis.core.domain.QueueEntryId
import com.auralis.core.domain.ReplayGainCalculator
import com.auralis.core.domain.ReplayGainSettings
import com.auralis.core.domain.Track
import java.io.File
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient

/**
 * Media3 播放引擎。
 *
 * 承担 Apple `AVFoundationPlaybackEngine` + 队列编排的职责：
 * - **单一 ExoPlayer 实例**，长期复用，绝不每切歌/重建 new 一个；
 * - **逻辑队列 + 窗口化呈现**（见 [QueueWindowing]），MediaItem.mediaId = QueueEntryId；
 * - 播放状态与队列状态**分流**：position 高频变化不影响队列 UI；
 * - stall 15s 超时、流失败 ≤2 次重试（重新 resolve URL）、失败后 canGoNext 自动下一首；
 * - 播放模式一个按钮循环（顺序→随机→列表循环→单曲循环）；
 * - 速度 0.5–2.0 跨切歌/暂停保持；ReplayGain 作用于 player volume，不覆盖用户音量偏好；
 * - 锁屏/后台：由 [AuralisPlaybackService]（MediaSessionService）持有本引擎，
 *   进程活着音乐就不中断（Activity 重建/页面切换不受影响）。
 */
@OptIn(UnstableApi::class)
class AuralisPlaybackEngine(
    context: Context,
    private val resolver: PlaybackSourceResolver,
    okHttpClient: OkHttpClient = defaultOkHttpClient(),
    /** 播放历史/scrobble 下沉（core:data 实现）；null 表示不记录。 */
    private val historySink: PlaybackHistorySink? = null,
) {
    private val appContext = context.applicationContext
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    // ------------------------------------------------------------ 播放器本体
    val player: ExoPlayer = run {
        val okHttpDataSourceFactory = OkHttpDataSource.Factory(okHttpClient)
        val dataSourceFactory = DefaultDataSource.Factory(appContext, okHttpDataSourceFactory)
        ExoPlayer.Builder(appContext)
            .setRenderersFactory(
                DefaultRenderersFactory(appContext)
                    .setExtensionRendererMode(DefaultRenderersFactory.EXTENSION_RENDERER_MODE_PREFER),
            )
            .setMediaSourceFactory(DefaultMediaSourceFactory(dataSourceFactory))
            .setAudioAttributes(AudioAttributes.Builder().setUsage(C.USAGE_MEDIA).build(), true)
            .setHandleAudioBecomingNoisy(true)
            .build()
    }

    // ------------------------------------------------------------- 双态分流
    private val playbackState = MutableStateFlow(PlaybackSnapshot.Empty)
    private val queueState = MutableStateFlow(QueueSnapshot.Empty)

    val playback: StateFlow<PlaybackSnapshot> = playbackState.asStateFlow()
    val queue: StateFlow<QueueSnapshot> = queueState.asStateFlow()

    // -------------------------------------------------------------- 逻辑队列
    private val logicalQueue = ArrayList<QueueEntry>()
    private var windowStart = 0
    private var windowEnd = 0
    private var currentLogical = -1

    private var playMode = PlayMode.Sequential
    private var userVolume = 1f
    private var playbackSpeed = 1f
    private var replayGain: ReplayGainSettings = ReplayGainSettings()
    private val retryAttempts = HashMap<String, Int>()

    private var stallTimeoutJob: Job? = null
    private var pendingHistory = HashMap<String, Boolean>()

    /** 已通知过“开始播放”的 occurrence（去重）。 */
    private var activatedEntryId: QueueEntryId? = null
    /** 已通知过“自然播完”的 occurrence（去重，防重复 scrobble/计数）。 */
    private val completedOccurrences = HashSet<String>()
    /** 真实解析来源：globalTrackId → 是否本地文件（P0-9：不再恒定 false）。 */
    private val localSourceKeys = HashMap<String, Boolean>()

    private val queueMutating = false

    init {
        player.addListener(object : Player.Listener {
            override fun onPlaybackStateChanged(state: Int) {
                when (state) {
                    Player.STATE_BUFFERING -> {
                        if (player.playWhenReady) enterBuffering()
                    }

                    Player.STATE_READY -> {
                        stallTimeoutJob?.cancel()
                        publishPlaybackState()
                    }

                    Player.STATE_ENDED -> {
                        stallTimeoutJob?.cancel()
                        notifyCompleted()
                        handleWindowExhausted()
                    }

                    else -> publishPlaybackState()
                }
            }

            override fun onIsPlayingChanged(isPlaying: Boolean) {
                if (isPlaying) stallTimeoutJob?.cancel()
                publishPlaybackState()
            }

            override fun onMediaItemTransition(mediaItem: MediaItem?, reason: Int) {
                updateCurrentFromPlayer()
                notifyActivated()
                publishPlaybackState()
                publishQueueState()
            }

            override fun onPlayerError(error: PlaybackException) {
                handleStreamFailure()
            }

            override fun onPositionDiscontinuity(
                oldPosition: Player.PositionInfo,
                newPosition: Player.PositionInfo,
                reason: Int,
            ) {
                updateCurrentFromPlayer()
                publishPlaybackState()
            }
        })
    }

    // --------------------------------------------------------------- 公开命令

    /** 播放一组队列（从 [startLogicalIndex] 开始）。occurrence UUID 全部保留。 */
    suspend fun playQueue(entries: List<QueueEntry>, startLogicalIndex: Int = 0, startAtMs: Long = 0) {
        if (entries.isEmpty()) return
        logicalQueue.clear()
        logicalQueue.addAll(entries)
        currentLogical = startLogicalIndex.coerceIn(0, entries.size - 1)
        stallTimeoutJob?.cancel()
        retryAttempts.clear()
        applyPlayModeToPlayer()
        awaitPlayAt(logicalIndex = currentLogical, startAtMs = startAtMs, seekMode = true)
    }

    /** 点击队列中某个 occurrence（按 entry id）播放。 */
    suspend fun playOccurrence(entryId: QueueEntryId) {
        val index = logicalIndexOf(entryId) ?: return
        currentLogical = index
        awaitPlayAt(logicalIndex = index, startAtMs = 0L, seekMode = true)
    }

    suspend fun playAtLogicalIndex(index: Int) {
        if (index < 0 || index >= logicalQueue.size) return
        currentLogical = index
        awaitPlayAt(logicalIndex = index, startAtMs = 0L, seekMode = true)
    }

    fun togglePlayPause() {
        if (player.isPlaying) {
            player.pause()
        } else {
            when (playbackState.value.state) {
                PlaybackState.Failed -> scope.launch { retryPlayback() }
                PlaybackState.Idle -> Unit
                else -> player.play()
            }
        }
        publishPlaybackState()
    }

    fun pause() {
        player.pause()
        publishPlaybackState()
    }

    suspend fun resume() {
        player.play()
        publishPlaybackState()
    }

    fun seekTo(positionMs: Long) {
        player.seekTo(maxOf(0, positionMs))
        publishPlaybackState()
    }

    fun next() {
        scope.launch { advanceUser() }
    }

    fun previous() {
        scope.launch {
            val position = player.currentPosition
            if (position > PREVIOUS_RESTART_THRESHOLD_MS) {
                player.seekTo(0)
                publishPlaybackState()
                return@launch
            }
            backUser()
        }
    }

    /** 播放模式按钮循环：顺序 → 随机 → 列表循环 → 单曲循环 → 顺序。 */
    fun cyclePlayMode() {
        playMode = playMode.next()
        applyPlayModeToPlayer()
        publishPlaybackState()
        publishQueueState()
    }

    fun setPlayMode(mode: PlayMode) {
        playMode = mode
        applyPlayModeToPlayer()
        publishPlaybackState()
    }

    fun setSpeed(speed: Float) {
        playbackSpeed = speed.coerceIn(0.5f, 2.0f)
        player.setPlaybackParameters(player.playbackParameters.withSpeed(playbackSpeed))
    }

    fun setVolume(volume: Float) {
        userVolume = volume.coerceIn(0f, 1f)
        applyReplayGainVolume()
    }

    fun configureReplayGain(settings: ReplayGainSettings) {
        replayGain = settings
        applyReplayGainVolume()
    }

    /** 删除队列 occurrence；删除当前项后自动续播。 */
    fun removeOccurrence(entryId: QueueEntryId) {
        val index = logicalIndexOf(entryId) ?: return
        val removedWasCurrent = index == currentLogical
        logicalQueue.removeAt(index)
        if (index < currentLogical) currentLogical -= 1
        if (logicalQueue.isEmpty()) {
            player.stop()
            player.clearMediaItems()
            currentLogical = -1
            windowStart = 0
            windowEnd = 0
            publishAll()
            return
        }
        if (removedWasCurrent) {
            currentLogical = currentLogical.coerceIn(0, logicalQueue.size - 1)
            scope.launch { awaitPlayAt(currentLogical, 0L, seekMode = true) }
        } else {
            refreshWindowPreservingPosition()
        }
    }

    fun moveOccurrence(fromEntryId: QueueEntryId, toIndexLogical: Int) {
        val from = logicalIndexOf(fromEntryId) ?: return
        if (from == toIndexLogical) return
        val entry = logicalQueue.removeAt(from)
        val target = toIndexLogical.coerceIn(0, logicalQueue.size)
        logicalQueue.add(target, entry)
        if (from == currentLogical) currentLogical = target
        else if (from < currentLogical && target >= currentLogical) currentLogical -= 1
        else if (from > currentLogical && target <= currentLogical) currentLogical += 1
        refreshWindowPreservingPosition()
    }

    /**
     * 下一首播放（对齐 Swift `playNext(tracks:)`）：把 [entries] 按序插到当前项之后，
     * 重复曲目创建独立 occurrence；尚未起播（currentLogical = -1）时插入队首。
     * 不改变当前曲目与播放进度——插入点若落在已物化窗口内则重建窗口（保位置），
     * 否则只更新逻辑队列与快照。
     */
    fun insertNext(entries: List<QueueEntry>) {
        if (entries.isEmpty()) return
        val insertAt = currentLogical + 1
        logicalQueue.addAll(insertAt, entries)
        // addAll 的插入点 ≥ currentLogical+1，当前项下标不受影响。
        if (player.mediaItemCount > 0) {
            refreshWindowPreservingPosition()
        } else {
            publishAll()
        }
    }

    /** 加入队列（对齐 Swift `appendToQueue`）：追加到逻辑队列末尾，不自动起播、不打断播放。 */
    fun appendToQueue(entries: List<QueueEntry>) {
        if (entries.isEmpty()) return
        logicalQueue.addAll(entries)
        publishAll()
    }

    /** 清空队列并停止。 */
    fun clearQueue() {
        logicalQueue.clear()
        player.stop()
        player.clearMediaItems()
        currentLogical = -1
        windowStart = 0
        windowEnd = 0
        retryAttempts.clear()
        stallTimeoutJob?.cancel()
        publishAll()
    }

    fun release() {
        stallTimeoutJob?.cancel()
        player.release()
        scope.cancel()
    }

    // ------------------------------------------------------------ 内部实现

    private fun applyPlayModeToPlayer() {
        player.repeatMode = when (playMode) {
            PlayMode.RepeatOne -> Player.REPEAT_MODE_ONE
            else -> Player.REPEAT_MODE_OFF
        }
    }

    /**
     * 起播（P0-9：音频首响优先）。
     * 只 resolve **当前这一首** 就交给 Media3 prepare/play；窗口其余部分在后台补齐，
     * 绝不先给 256 首逐首 resolve 认证 URL 再开始第一首。
     */
    private suspend fun awaitPlayAt(logicalIndex: Int, startAtMs: Long, seekMode: Boolean) {
        val window = QueueWindowing.initialWindow(logicalQueue.size, logicalIndex)
        windowStart = window.first
        windowEnd = window.last + 1
        val currentItem = buildMediaItemAt(logicalIndex) ?: return
        player.setMediaItems(listOf(currentItem), 0, startAtMs)
        player.prepare()
        player.play()
        updateCurrentFromPlayer()
        currentLogical = logicalIndex
        notifyActivated()
        publishAll()
        // 后台补齐窗口：先插当前之前，再追加之后（保持 current 位置 = index-windowStart）。
        scope.launch { fillWindowAround(logicalIndex) }
    }

    private suspend fun buildMediaItemAt(index: Int): MediaItem? =
        buildMediaItems(index, index + 1)?.firstOrNull()

    private suspend fun fillWindowAround(currentIndex: Int) {
        val before = buildMediaItems(windowStart, currentIndex).orEmpty()
        if (before.isNotEmpty()) {
            withContext(Dispatchers.Main) { player.addMediaItems(0, before) }
        }
        val after = buildMediaItems(currentIndex + 1, windowEnd).orEmpty()
        if (after.isNotEmpty()) {
            withContext(Dispatchers.Main) { player.addMediaItems(after) }
        }
        withContext(Dispatchers.Main) {
            currentLogical = currentIndex
            publishAll()
        }
    }

    /** 生成窗口 MediaItems；任何一条无法 resolve 会被替换为占位（防止窗口整体失败）。 */
    private suspend fun buildMediaItems(start: Int, end: Int): List<MediaItem>? {
        if (logicalQueue.isEmpty()) return null
        val items = ArrayList<MediaItem>(end - start)
        for (i in start until end) {
            val entry = logicalQueue.getOrNull(i) ?: continue
            val resolved = withContext(Dispatchers.IO) {
                runCatching { resolver.resolve(entry.track) }.getOrNull()
            }
            val uri = when (resolved) {
                is com.auralis.core.domain.ResolvedSource.Local -> Uri.fromFile(File(resolved.path))
                is com.auralis.core.domain.ResolvedSource.Remote -> Uri.parse(resolved.url)
                else -> null
            }
            // 真实解析结果：本地/远端。以后歌曲信息页的“播放来源”取自这里。
            localSourceKeys[entry.track.globalId.serialized] =
                resolved is com.auralis.core.domain.ResolvedSource.Local
            val builder = MediaItem.Builder()
                .setMediaId(entry.id.value)
                .setMediaMetadata(
                    MediaMetadata.Builder()
                        .setTitle(entry.track.title)
                        .setArtist(entry.track.artistName)
                        .setAlbumTitle(entry.track.albumTitle)
                        .setIsBrowsable(false)
                        .setIsPlayable(true)
                        .setExtras(android.os.Bundle().apply {
                            putString("globalTrackId", entry.track.globalId.serialized)
                            putString("serverId", entry.track.serverId.value)
                            putString("remoteTrackId", entry.track.id.value)
                        })
                        .build(),
                )
            if (uri != null) builder.setUri(uri)
            items.add(builder.build())
        }
        return items
    }

    private fun updateCurrentFromPlayer() {
        val indexInWindow = player.currentMediaItemIndex
        if (indexInWindow in 0 until player.mediaItemCount && indexInWindow >= 0) {
            val mediaItem = player.getMediaItemAt(indexInWindow)
            val entryId = QueueEntryId(mediaItem.mediaId)
            val windowIndex = (windowStart + indexInWindow)
            if (windowIndex - windowStart == indexInWindow) {
                currentLogical = windowStart + indexInWindow
            }
            @Suppress("UNUSED_VARIABLE")
            val unused = entryId
        }
    }

    /** 通知历史协调器：新 occurrence 开始播放（同 occurrence 只通知一次）。 */
    private fun notifyActivated() {
        val entry = currentQueueEntry() ?: return
        if (activatedEntryId == entry.id) return
        activatedEntryId = entry.id
        val sink = historySink ?: return
        scope.launch { runCatching { sink.onOccurrenceActivated(entry, entry.track) } }
    }

    /** 通知历史协调器：occurrence 自然播完（同 occurrence 只通知一次）。 */
    private fun notifyCompleted() {
        val entry = currentQueueEntry() ?: return
        if (!completedOccurrences.add(entry.id.value)) return
        val sink = historySink ?: return
        val playedMs = player.duration.coerceAtLeast(0)
        scope.launch { runCatching { sink.onOccurrenceCompleted(entry, entry.track, playedMs) } }
    }

    private fun currentQueueEntry(): QueueEntry? = logicalQueue.getOrNull(currentLogical)

    private fun publishAll() {
        publishPlaybackState()
        publishQueueState()
    }

    private fun publishPlaybackState() {
        val current = playbackState.value
        val mediaItemIndex = player.currentMediaItemIndex
        val entry = if (mediaItemIndex in 0 until player.mediaItemCount) {
            logicalQueue.getOrNull(windowStart + mediaItemIndex)
        } else {
            null
        }
        val state = when {
            player.playerError != null -> PlaybackState.Failed(PlaybackError.EngineFailure("播放中途失败"))
            player.playbackState == Player.STATE_BUFFERING -> PlaybackState.Buffering
            player.isPlaying -> PlaybackState.Playing
            player.playbackState == Player.STATE_READY && !player.playWhenReady -> PlaybackState.Paused
            player.playbackState == Player.STATE_IDLE -> PlaybackState.Idle
            else -> PlaybackState.Preparing
        }
        playbackState.value = PlaybackSnapshot(
            state = state,
            entry = entry,
            track = entry?.track,
            positionMs = player.currentPosition.coerceAtLeast(0),
            durationMs = player.duration.coerceAtLeast(0).let { if (it == C.TIME_UNSET) 0 else it },
            isBuffering = player.playbackState == Player.STATE_BUFFERING,
            speed = playbackSpeed,
            playMode = playMode,
            volume = userVolume,
            isLocalSource = entry?.track?.let { isDownloaded(it) } ?: false,
        )
    }

    /** 当前 occurrence 是否真的在用本地文件播放（来自 resolver 的真实解析结果）。 */
    private fun isDownloaded(track: Track): Boolean =
        localSourceKeys[track.globalId.serialized] == true

    private fun publishQueueState() {
        val windowIndex = player.currentMediaItemIndex
        val entries = logicalQueue.subList(windowStart, minOf(windowEnd, logicalQueue.size))
        queueState.value = QueueSnapshot(
            entries = entries,
            windowStartLogicalIndex = windowStart,
            currentEntryId = entries.getOrNull(windowIndex)?.id,
            currentWindowIndex = if (windowIndex in entries.indices) windowIndex else null,
            currentLogicalIndex = if (currentLogical in logicalQueue.indices) currentLogical else null,
            totalCount = logicalQueue.size,
            hasMoreBehindWindow = windowEnd < logicalQueue.size,
        )
    }

    // ------------------------------------------------------------ 播完/失败

    private fun handleWindowExhausted() {
        // 单曲循环交给 ExoPlayer repeatMode=ONE，不会走到这里
        val lastPlayedLogical = windowStart + (player.mediaItemCount - 1)
        val atLogicalEnd = windowEnd >= logicalQueue.size
        if (!atLogicalEnd && logicalQueue.size > QueueWindowing.LARGE_CONTEXT_THRESHOLD) {
            // 窗口尚未到底：续 192 并继续
            scope.launch {
                val newEnd = minOf(logicalQueue.size, windowEnd + QueueWindowing.LARGE_WINDOW_REFILL_BATCH)
                val extra = buildMediaItems(windowEnd, newEnd) ?: return@launch
                player.addMediaItems(extra)
                windowEnd = newEnd
                if (player.playbackState == Player.STATE_ENDED) {
                    player.prepare()
                }
                player.seekToNextMediaItem()
                player.play()
                publishAll()
            }
            return
        }
        // 逻辑队尾
        when (playMode) {
            PlayMode.RepeatAll -> {
                val target = 0
                scope.launch { awaitPlayAt(target, 0L, seekMode = true) }
            }

            PlayMode.Shuffle -> {
                scope.launch { advanceUser(force = true) }
            }

            PlayMode.RepeatOne -> {
                player.seekTo(0)
                player.play()
            }

            PlayMode.Sequential -> {
                // 停在队尾（对齐 pauseAtQueueEnd）
                player.pause()
                publishPlaybackState()
            }
        }
    }

    /** 用户主动 next / shuffle / 失败自动下一首。 */
    private suspend fun advanceUser(force: Boolean = false) {
        val total = logicalQueue.size
        if (total == 0) return
        val target = when (playMode) {
            PlayMode.Shuffle -> {
                val played = HashSet<Int>()
                val candidates = (0 until total).filter { it != currentLogical && it !in played }
                if (candidates.isEmpty()) {
                    if (playMode == PlayMode.Shuffle && !force) return
                    (0 until total).filter { it != currentLogical }.randomOrNull() ?: currentLogical
                } else {
                    candidates.random()
                }
            }

            PlayMode.RepeatOne -> currentLogical

            else -> {
                val next = (currentLogical ?: -1) + 1
                if (next < total) next
                else if (playMode == PlayMode.RepeatAll) 0 else return
            }
        }
        if (target == currentLogical && playMode == PlayMode.RepeatOne) {
            player.seekTo(0)
            player.play()
            return
        }
        if (target < 0) return
        currentLogical = target
        awaitPlayAt(target, 0L, seekMode = true)
    }

    private suspend fun backUser() {
        val total = logicalQueue.size
        if (total == 0) return
        val previous = (currentLogical ?: 0) - 1
        val target = if (previous >= 0) previous else if (playMode == PlayMode.RepeatAll) total - 1 else return
        currentLogical = target
        awaitPlayAt(target, 0L, seekMode = true)
    }

    // ------------------------------------------------------------- 失败恢复

    private fun enterBuffering() {
        stallTimeoutJob?.cancel()
        stallTimeoutJob = scope.launch {
            delay(STALL_TIMEOUT_MS)
            if (playbackState.value.state is PlaybackState.Buffering || playbackState.value.state == PlaybackState.Stalled) {
                handleStreamFailure()
            }
        }
        publishPlaybackState()
    }

    /** 流失败恢复：重新 resolve URL，重试预算 2 次/曲；耗尽后 canGoNext 自动下一首。 */
    private fun handleStreamFailure() {
        val track = playbackState.value.track ?: return
        val key = track.globalId.serialized
        val attempts = retryAttempts[key] ?: 0
        stallTimeoutJob?.cancel()
        if (attempts >= MAX_STREAM_RETRY_ATTEMPTS) {
            retryAttempts.remove(key)
            playbackState.value = playbackState.value.copy(
                state = PlaybackState.Failed(PlaybackError.EngineFailure("流地址失效，已重试仍无法播放")),
            )
            scope.launch {
                val canGoNext = playMode != PlayMode.RepeatOne &&
                    (currentLogical ?: -1) < logicalQueue.size - 1
                if (canGoNext) advanceUser() else pause()
            }
            return
        }
        retryAttempts[key] = attempts + 1
        scope.launch {
            playbackState.value = playbackState.value.copy(state = PlaybackState.Buffering)
            val refreshed = withContext(Dispatchers.IO) {
                runCatching { resolver.resolve(track, forceRefresh = true) }.getOrNull()
            }
            val remoteUrl = (refreshed as? com.auralis.core.domain.ResolvedSource.Remote)?.url
            val localPath = (refreshed as? com.auralis.core.domain.ResolvedSource.Local)?.path
            val url = remoteUrl ?: localPath
            if (url == null) {
                retryAttempts[key] = MAX_STREAM_RETRY_ATTEMPTS
                handleStreamFailure()
                return@launch
            }
            val uri = if (localPath != null) Uri.fromFile(File(localPath)) else Uri.parse(remoteUrl)
            replaceCurrentWindowItem(uri)
            player.prepare()
            player.play()
            publishAll()
        }
    }

    /** 用户手动重试。 */
    private suspend fun retryPlayback() {
        val track = playbackState.value.track ?: return
        playbackState.value = playbackState.value.copy(state = PlaybackState.Buffering)
        val resolved = withContext(Dispatchers.IO) {
            runCatching { resolver.resolve(track, forceRefresh = true) }.getOrNull()
        }
        val remoteUrl = (resolved as? com.auralis.core.domain.ResolvedSource.Remote)?.url
        val localPath = (resolved as? com.auralis.core.domain.ResolvedSource.Local)?.path
        val uri = if (localPath != null) Uri.fromFile(File(localPath)) else remoteUrl?.let { Uri.parse(it) }
        if (uri == null) {
            playbackState.value = playbackState.value.copy(
                state = PlaybackState.Failed(PlaybackError.EngineFailure("无法解析播放地址")),
            )
            return
        }
        replaceCurrentWindowItem(uri)
        player.prepare()
        player.play()
    }

    // ------------------------------------------------------------------ 工具

    private fun logicalIndexOf(entryId: QueueEntryId): Int? =
        logicalQueue.indexOfFirst { it.id == entryId }.takeIf { it >= 0 }

    /** 队列编辑后保持当前曲目与进度：重建窗口并把播放器移到同一 logical index。 */
    private fun refreshWindowPreservingPosition() {
        scope.launch {
            if (logicalQueue.isEmpty()) return@launch
            val logical = (currentLogical ?: 0).coerceIn(0, logicalQueue.size - 1)
            currentLogical = logical
            val position = player.currentPosition.coerceAtLeast(0)
            val window = QueueWindowing.initialWindow(logicalQueue.size, logical)
            windowStart = window.first
            windowEnd = window.last + 1
            val items = buildMediaItems(windowStart, windowEnd) ?: return@launch
            val windowIndex = logical - windowStart
            player.setMediaItems(items, windowIndex, position)
            if (player.playWhenReady) {
                player.prepare()
                player.play()
            } else {
                player.prepare()
            }
            publishAll()
        }
    }

    /** 仅替换当前窗口内当前曲目的 URI（失败重试用），保留窗口上下文与进度。 */
    private fun replaceCurrentWindowItem(uri: Uri) {
        val index = player.currentMediaItemIndex.coerceAtLeast(0)
        val count = player.mediaItemCount
        if (index !in 0 until count) return
        val items = (0 until count).map { i ->
            val item = player.getMediaItemAt(i)
            if (i == index) item.buildUpon().setUri(uri).build() else item
        }
        player.setMediaItems(items, index, player.currentPosition.coerceAtLeast(0))
    }

    private fun applyReplayGainVolume() {
        val track = playbackState.value.track
        val metadata = track?.sourceInfo?.replayGain
        val adjustment = ReplayGainCalculator.adjustment(metadata, replayGain)
        val effective = (userVolume * adjustment.linearMultiplier).coerceIn(0f, 1f)
        player.volume = effective
    }

    companion object {
        private const val STALL_TIMEOUT_MS = 15_000L
        const val MAX_STREAM_RETRY_ATTEMPTS = 2
        const val PREVIOUS_RESTART_THRESHOLD_MS = 3_000L

        private fun defaultOkHttpClient(): OkHttpClient =
            OkHttpClient.Builder()
                .connectTimeout(30, TimeUnit.SECONDS)
                .readTimeout(60, TimeUnit.SECONDS)
                .build()
    }
}
