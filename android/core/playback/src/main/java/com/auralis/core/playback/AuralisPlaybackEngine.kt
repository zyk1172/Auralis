// SPDX-License-Identifier: GPL-3.0-only
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
import androidx.media3.session.MediaSession
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
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient

/**
 * Media3 playback engine.
 *
 * The logical occurrence queue and the materialized Media3 list deliberately remain separate. A
 * requested track is installed first for low first-audio latency; neighbours are resolved later.
 * Crucially, [windowStart]/[windowEnd] always describe what Media3 actually contains at that moment,
 * not the desired prefetch range. That invariant prevents a temporary media index 0 from being
 * published as logical queue item 0 when the user actually selected item N.
 */
@OptIn(UnstableApi::class)
class AuralisPlaybackEngine(
    context: Context,
    private val resolver: PlaybackSourceResolver,
    okHttpClient: OkHttpClient = defaultOkHttpClient(),
    private val historySink: PlaybackHistorySink? = null,
) {
    private val appContext = context.applicationContext
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

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

    private val playbackState = MutableStateFlow(PlaybackSnapshot.Empty)
    private val queueState = MutableStateFlow(QueueSnapshot.Empty)
    val playback: StateFlow<PlaybackSnapshot> = playbackState.asStateFlow()
    val queue: StateFlow<QueueSnapshot> = queueState.asStateFlow()

    private val positionTicker = MutableStateFlow(0L)
    val position: StateFlow<Long> = positionTicker.asStateFlow()

    private val logicalQueue = ArrayList<QueueEntry>()

    /** The range that is currently materialized inside [player], not a future prefetch target. */
    private var windowStart = 0
    private var windowEnd = 0
    private var currentLogical = -1

    /** Invalidates slow background neighbour hydration after another user navigation wins. */
    private var windowGeneration = 0L

    /** Suppresses transient Player callbacks while a Media3 list is being structurally rewritten. */
    private var playerListMutation = false

    private var playMode = PlayMode.Sequential
    private var userVolume = 1f
    private var playbackSpeed = 1f
    private var replayGain: ReplayGainSettings = ReplayGainSettings()
    private val retryAttempts = HashMap<String, Int>()
    private var stallTimeoutJob: Job? = null

    private var activatedEntryId: QueueEntryId? = null
    private val completedOccurrences = HashSet<String>()
    private val localSourceKeys = HashMap<String, Boolean>()

    init {
        player.addListener(object : Player.Listener {
            override fun onPlaybackStateChanged(state: Int) {
                if (playerListMutation) return
                when (state) {
                    Player.STATE_BUFFERING -> if (player.playWhenReady) enterBuffering()
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
                if (playerListMutation) return
                if (isPlaying) stallTimeoutJob?.cancel()
                publishPlaybackState()
            }

            override fun onMediaItemTransition(mediaItem: MediaItem?, reason: Int) {
                if (playerListMutation) return
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
                if (playerListMutation) return
                updateCurrentFromPlayer()
                publishPlaybackState()
            }
        })

        scope.launch {
            while (isActive) {
                val pos = player.currentPosition.coerceAtLeast(0)
                if (pos != positionTicker.value) positionTicker.value = pos
                delay(250L)
            }
        }
    }

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

    /**
     * Rebuilds the engine-side occurrence model before MediaSession applies a playback-resumption
     * playlist. Neighbours that can no longer resolve are dropped; the current occurrence is
     * mandatory. This prevents an externally restored Media3 playlist from existing without a
     * corresponding Auralis logical queue.
     */
    internal suspend fun preparePlaybackResumption(
        snapshot: PersistedPlaybackSession,
    ): MediaSession.MediaItemsWithStartPosition? {
        if (snapshot.entries.isEmpty() || snapshot.currentIndex !in snapshot.entries.indices) return null

        val resolvedEntries = ArrayList<QueueEntry>(snapshot.entries.size)
        val resolvedItems = ArrayList<MediaItem>(snapshot.entries.size)
        var resolvedCurrent = -1

        snapshot.entries.forEachIndexed { index, persisted ->
            val entry = persisted.toQueueEntry()
            val item = buildMediaItem(entry, requireUri = true)
            if (item == null) {
                if (index == snapshot.currentIndex) return null
                return@forEachIndexed
            }
            if (index == snapshot.currentIndex) resolvedCurrent = resolvedItems.size
            resolvedEntries.add(entry)
            resolvedItems.add(item)
        }
        if (resolvedCurrent !in resolvedItems.indices) return null

        windowGeneration += 1
        logicalQueue.clear()
        logicalQueue.addAll(resolvedEntries)
        currentLogical = resolvedCurrent
        windowStart = 0
        windowEnd = logicalQueue.size
        playMode = snapshot.playMode
        playbackSpeed = snapshot.speed.coerceIn(0.5f, 2.0f)
        retryAttempts.clear()
        applyPlayModeToPlayer()
        player.setPlaybackParameters(player.playbackParameters.withSpeed(playbackSpeed))
        positionTicker.value = snapshot.positionMs.coerceAtLeast(0L)

        val currentEntry = logicalQueue[currentLogical]
        playbackState.value = PlaybackSnapshot(
            state = PlaybackState.Paused,
            entry = currentEntry,
            track = currentEntry.track,
            positionMs = snapshot.positionMs.coerceAtLeast(0L),
            durationMs = (currentEntry.track.durationSeconds * 1000.0).toLong().coerceAtLeast(0L),
            speed = playbackSpeed,
            playMode = playMode,
            volume = userVolume,
            isLocalSource = localSourceKeys[currentEntry.track.globalId.serialized] == true,
        )
        publishQueueState()

        return MediaSession.MediaItemsWithStartPosition(
            resolvedItems,
            resolvedCurrent,
            snapshot.positionMs.coerceAtLeast(0L),
        )
    }

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
                is PlaybackState.Failed -> scope.launch { retryPlayback() }
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
            if (PlaybackLogic.shouldRestartInsteadOfPrevious(position)) {
                player.seekTo(0)
                publishPlaybackState()
                return@launch
            }
            backUser()
        }
    }

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
        publishPlaybackState()
    }

    fun setVolume(volume: Float) {
        userVolume = volume.coerceIn(0f, 1f)
        applyReplayGainVolume()
        publishPlaybackState()
    }

    fun configureReplayGain(settings: ReplayGainSettings) {
        replayGain = settings
        applyReplayGainVolume()
    }

    fun removeOccurrence(entryId: QueueEntryId) {
        val index = logicalIndexOf(entryId) ?: return
        val removedWasCurrent = index == currentLogical
        logicalQueue.removeAt(index)
        if (!removedWasCurrent) {
            currentLogical = PlaybackLogic.currentAfterRemove(index, currentLogical)
        }
        if (logicalQueue.isEmpty()) {
            windowGeneration += 1
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
        currentLogical = PlaybackLogic.currentAfterMove(from, target, currentLogical)
        refreshWindowPreservingPosition()
    }

    fun insertNext(entries: List<QueueEntry>) {
        if (entries.isEmpty()) return
        val insertAt = (currentLogical + 1).coerceIn(0, logicalQueue.size)
        logicalQueue.addAll(insertAt, entries)
        if (player.mediaItemCount > 0) refreshWindowPreservingPosition() else publishAll()
    }

    fun appendToQueue(entries: List<QueueEntry>) {
        if (entries.isEmpty()) return
        logicalQueue.addAll(entries)
        publishAll()
    }

    fun clearQueue() {
        windowGeneration += 1
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
        windowGeneration += 1
        stallTimeoutJob?.cancel()
        player.release()
        scope.cancel()
    }

    private fun applyPlayModeToPlayer() {
        player.repeatMode = when (playMode) {
            PlayMode.RepeatOne -> Player.REPEAT_MODE_ONE
            else -> Player.REPEAT_MODE_OFF
        }
    }

    private suspend fun awaitPlayAt(logicalIndex: Int, startAtMs: Long, seekMode: Boolean) {
        val generation = ++windowGeneration
        val targetWindow = QueueWindowing.initialWindow(logicalQueue.size, logicalIndex)
        val entry = logicalQueue.getOrNull(logicalIndex) ?: return
        val currentItem = buildMediaItem(entry, requireUri = true)

        if (generation != windowGeneration) return

        val currentOnly = PlaybackWindowIdentity.currentOnly(logicalIndex)
        currentLogical = logicalIndex
        windowStart = currentOnly.first
        windowEnd = currentOnly.last + 1

        if (currentItem == null) {
            playerListMutation = true
            try {
                player.stop()
                player.clearMediaItems()
            } finally {
                playerListMutation = false
            }
            positionTicker.value = 0L
            playbackState.value = PlaybackSnapshot(
                state = PlaybackState.Failed(PlaybackError.EngineFailure("无法解析播放地址")),
                entry = entry,
                track = entry.track,
                positionMs = 0L,
                durationMs = (entry.track.durationSeconds * 1000.0).toLong().coerceAtLeast(0L),
                speed = playbackSpeed,
                playMode = playMode,
                volume = userVolume,
                isLocalSource = false,
            )
            publishQueueState()
            return
        }

        playerListMutation = true
        try {
            player.setMediaItems(listOf(currentItem), 0, startAtMs)
        } finally {
            playerListMutation = false
        }
        player.prepare()
        player.play()
        currentLogical = logicalIndex
        notifyActivated()
        publishAll()

        scope.launch {
            fillWindowAround(
                currentIndex = logicalIndex,
                targetStart = targetWindow.first,
                targetEnd = targetWindow.last + 1,
                generation = generation,
            )
        }
    }

    private suspend fun fillWindowAround(
        currentIndex: Int,
        targetStart: Int,
        targetEnd: Int,
        generation: Long,
    ) {
        val before = buildMediaItems(targetStart, currentIndex).orEmpty()
        if (generation != windowGeneration) return
        val after = buildMediaItems(currentIndex + 1, targetEnd).orEmpty()
        if (generation != windowGeneration) return

        withContext(Dispatchers.Main) {
            if (generation != windowGeneration || currentLogical != currentIndex) return@withContext
            playerListMutation = true
            try {
                if (before.isNotEmpty()) player.addMediaItems(0, before)
                if (after.isNotEmpty()) player.addMediaItems(after)
                windowStart = targetStart
                windowEnd = targetEnd
                currentLogical = currentIndex
            } finally {
                playerListMutation = false
            }
            updateCurrentFromPlayer()
            currentLogical = currentIndex
            publishAll()
        }
    }

    private suspend fun buildMediaItems(start: Int, end: Int): List<MediaItem>? {
        if (logicalQueue.isEmpty()) return null
        val items = ArrayList<MediaItem>(end - start)
        for (i in start until end) {
            val entry = logicalQueue.getOrNull(i) ?: continue
            buildMediaItem(entry, requireUri = false)?.let(items::add)
        }
        return items
    }

    private suspend fun buildMediaItem(entry: QueueEntry, requireUri: Boolean): MediaItem? {
        val resolved = withContext(Dispatchers.IO) {
            runCatching { resolver.resolve(entry.track) }.getOrNull()
        }
        val uri = when (resolved) {
            is com.auralis.core.domain.ResolvedSource.Local -> Uri.fromFile(File(resolved.path))
            is com.auralis.core.domain.ResolvedSource.Remote -> Uri.parse(resolved.url)
            else -> null
        }
        localSourceKeys[entry.track.globalId.serialized] =
            resolved is com.auralis.core.domain.ResolvedSource.Local
        if (requireUri && uri == null) return null

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
        return builder.build()
    }

    private fun updateCurrentFromPlayer() {
        val indexInWindow = player.currentMediaItemIndex
        if (indexInWindow in 0 until player.mediaItemCount && indexInWindow >= 0) {
            currentLogical = PlaybackWindowIdentity.logicalIndex(windowStart, indexInWindow)
        }
    }

    private fun notifyActivated() {
        val entry = currentQueueEntry() ?: return
        if (activatedEntryId == entry.id) return
        activatedEntryId = entry.id
        val sink = historySink ?: return
        scope.launch { runCatching { sink.onOccurrenceActivated(entry, entry.track) } }
    }

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
        val mediaItemIndex = player.currentMediaItemIndex
        val entry = if (mediaItemIndex in 0 until player.mediaItemCount) {
            logicalQueue.getOrNull(
                PlaybackWindowIdentity.logicalIndex(windowStart, mediaItemIndex),
            )
        } else {
            logicalQueue.getOrNull(currentLogical)
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

    private fun isDownloaded(track: Track): Boolean =
        localSourceKeys[track.globalId.serialized] == true

    private fun publishQueueState() {
        if (logicalQueue.isEmpty()) {
            queueState.value = QueueSnapshot.Empty
            return
        }
        val safeStart = windowStart.coerceIn(0, logicalQueue.size)
        val safeEnd = windowEnd.coerceIn(safeStart, logicalQueue.size)
        // QueueSnapshot is a value object. Never expose ArrayList.SubList here: that object keeps a
        // live modCount link to logicalQueue and throws ConcurrentModificationException as soon as
        // playback hydration/navigation mutates the backing queue while an older UI snapshot is
        // still being iterated.
        val entries = logicalQueue.subList(safeStart, safeEnd).toList()
        val playerIndex = player.currentMediaItemIndex
        val logicalWindowIndex = (currentLogical - safeStart).takeIf { it in entries.indices }
        val windowIndex = playerIndex.takeIf { it in entries.indices } ?: logicalWindowIndex
        queueState.value = QueueSnapshot(
            entries = entries,
            windowStartLogicalIndex = safeStart,
            currentEntryId = windowIndex?.let { entries.getOrNull(it)?.id },
            currentWindowIndex = windowIndex,
            currentLogicalIndex = if (currentLogical in logicalQueue.indices) currentLogical else null,
            totalCount = logicalQueue.size,
            hasMoreBehindWindow = safeEnd < logicalQueue.size,
        )
    }

    private fun handleWindowExhausted() {
        val atLogicalEnd = windowEnd >= logicalQueue.size
        if (!atLogicalEnd && logicalQueue.size > QueueWindowing.LARGE_CONTEXT_THRESHOLD) {
            scope.launch {
                val generation = windowGeneration
                val oldEnd = windowEnd
                val newEnd = minOf(logicalQueue.size, oldEnd + QueueWindowing.LARGE_WINDOW_REFILL_BATCH)
                val extra = buildMediaItems(oldEnd, newEnd) ?: return@launch
                if (generation != windowGeneration) return@launch
                player.addMediaItems(extra)
                windowEnd = newEnd
                if (player.playbackState == Player.STATE_ENDED) player.prepare()
                player.seekToNextMediaItem()
                player.play()
                publishAll()
            }
            return
        }
        when (playMode) {
            PlayMode.RepeatAll -> scope.launch { awaitPlayAt(0, 0L, seekMode = true) }
            PlayMode.Shuffle -> scope.launch { advanceUser(force = true) }
            PlayMode.RepeatOne -> {
                player.seekTo(0)
                player.play()
            }
            PlayMode.Sequential -> {
                player.pause()
                publishPlaybackState()
            }
        }
    }

    private suspend fun advanceUser(force: Boolean = false) {
        val total = logicalQueue.size
        if (total == 0) return
        val target = PlaybackLogic.nextTarget(playMode, currentLogical, total, force) ?: return
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
        val target = PlaybackLogic.previousTarget(playMode, currentLogical, total) ?: return
        currentLogical = target
        awaitPlayAt(target, 0L, seekMode = true)
    }

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
                val canGoNext = PlaybackLogic.canAutoAdvanceAfterFailure(playMode, currentLogical, logicalQueue.size)
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

    private fun logicalIndexOf(entryId: QueueEntryId): Int? =
        logicalQueue.indexOfFirst { it.id == entryId }.takeIf { it >= 0 }

    private fun refreshWindowPreservingPosition() {
        scope.launch {
            if (logicalQueue.isEmpty()) return@launch
            val logical = currentLogical.coerceIn(0, logicalQueue.size - 1)
            currentLogical = logical
            val position = player.currentPosition.coerceAtLeast(0)
            val targetWindow = QueueWindowing.initialWindow(logicalQueue.size, logical)
            val targetStart = targetWindow.first
            val targetEnd = targetWindow.last + 1
            val generation = ++windowGeneration
            val items = buildMediaItems(targetStart, targetEnd) ?: return@launch
            if (generation != windowGeneration) return@launch
            val windowIndex = logical - targetStart

            playerListMutation = true
            try {
                player.setMediaItems(items, windowIndex, position)
                windowStart = targetStart
                windowEnd = targetEnd
                currentLogical = logical
            } finally {
                playerListMutation = false
            }
            if (player.playWhenReady) {
                player.prepare()
                player.play()
            } else {
                player.prepare()
            }
            publishAll()
        }
    }

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

        private fun defaultOkHttpClient(): OkHttpClient =
            OkHttpClient.Builder()
                .connectTimeout(30, TimeUnit.SECONDS)
                .readTimeout(60, TimeUnit.SECONDS)
                .build()
    }
}
