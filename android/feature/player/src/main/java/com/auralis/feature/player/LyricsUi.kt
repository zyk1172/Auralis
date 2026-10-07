// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
package com.auralis.feature.player

import android.icu.text.BreakIterator
import android.os.SystemClock
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.drawscope.clipRect
import androidx.compose.ui.graphics.drawscope.withTransform
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.text.drawText
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.auralis.core.designsystem.AuralisSpacing
import com.auralis.core.designsystem.LocalAuralisTheme
import com.auralis.core.designsystem.LocalReduceMotion
import com.auralis.core.domain.LyricsDocument
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.yield

/** Native drag/fling suspends follow; our own scroll animation never starts a browsing session. */
@Stable
internal class LyricsScrollFollowState {
    var isUserScrolling by mutableStateOf(false)
        private set
    var isFollowingPlayback by mutableStateOf(true)
        private set

    fun beginUserScroll() {
        isUserScrolling = true
        isFollowingPlayback = false
    }

    fun endUserScroll() { isUserScrolling = false }

    fun resumeFollowing() {
        if (!isUserScrolling) isFollowingPlayback = true
    }
}

@Composable
internal fun SyncedLyricsContent(
    doc: LyricsDocument,
    positionMs: Long,
    isPlaying: Boolean,
    isPageActive: Boolean,
    followState: LyricsScrollFollowState,
    listState: LazyListState = rememberLazyListState(),
    speed: Float = 1f,
) {
    val reduceMotion = LocalReduceMotion.current
    val density = LocalDensity.current
    val synced = doc.isSynced && doc.lines.all { it.startTimeSeconds != null }
    val activeIndex = if (synced) {
        doc.lines.indexOfLast { (it.startTimeSeconds ?: Double.MAX_VALUE) <= positionMs / 1000.0 + 0.05 }
            .takeIf { it >= 0 }
    } else null
    var touching by remember(doc) { mutableStateOf(false) }

    LaunchedEffect(listState, followState, isPageActive) {
        if (!isPageActive) return@LaunchedEffect
        snapshotFlow { touching || listState.isScrollInProgress }
            .distinctUntilChanged().collect { moving ->
                // Only a pointer starts browsing. Programmatic follow may also move the list.
                if (!moving && followState.isUserScrolling) followState.endUserScroll()
            }
    }
    LaunchedEffect(followState.isUserScrolling, followState.isFollowingPlayback, isPageActive) {
        if (isPageActive && !followState.isUserScrolling && !followState.isFollowingPlayback) {
            delay(NowPlayingUiPolicy.lyricsFollowResumeDelayMs)
            followState.resumeFollowing()
        }
    }
    LaunchedEffect(activeIndex, doc, reduceMotion, isPageActive,
        followState.isFollowingPlayback, followState.isUserScrolling) {
        val target = activeIndex ?: return@LaunchedEffect
        if (!isPageActive || !followState.isFollowingPlayback || followState.isUserScrolling) return@LaunchedEffect
        yield()
        val viewport = listState.layoutInfo.viewportSize.height
        val halfLine = listState.layoutInfo.visibleItemsInfo.firstOrNull { it.index == target }
            ?.size?.div(2) ?: with(density) { 12.dp.roundToPx() }
        val offset = -(viewport / 2 - halfLine).coerceAtLeast(0)
        if (reduceMotion) listState.scrollToItem(target, offset)
        else listState.animateScrollToItem(target, offset)
    }
    LazyColumn(
        state = listState,
        modifier = Modifier.fillMaxSize().testTag("player.lyricsScroll")
            .pointerInput(doc.globalId, followState, isPageActive) {
                if (!isPageActive) return@pointerInput
                awaitEachGesture {
                    awaitFirstDown(requireUnconsumed = false, pass = PointerEventPass.Initial)
                    touching = true
                    followState.beginUserScroll()
                    try {
                        do {
                            val event = awaitPointerEvent(PointerEventPass.Initial)
                        } while (event.changes.any { it.pressed })
                    } finally {
                        touching = false
                    }
                }
            },
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(AuralisSpacing.large),
        contentPadding = PaddingValues(vertical = AuralisSpacing.huge),
    ) {
        itemsIndexed(doc.lines, key = { index, _ -> index }) { index, line ->
            AnimatedLyricLine(
                text = line.text,
                isCurrent = index == activeIndex,
                isPlaying = isPlaying,
                animate = isPageActive && !followState.isUserScrolling,
                positionMs = positionMs,
                start = line.startTimeSeconds,
                nextStart = doc.lines.drop(index + 1).firstNotNullOfOrNull { it.startTimeSeconds },
                modifier = Modifier.testTag("player.lyric.$index"),
                speed = speed,
            )
        }
    }
}

/** One native Text layout for every state, preserving wrapping, shaping and TalkBack text. */
@Composable
internal fun AnimatedLyricLine(
    text: String,
    isCurrent: Boolean,
    isPlaying: Boolean,
    animate: Boolean,
    positionMs: Long,
    start: Double?,
    nextStart: Double?,
    modifier: Modifier = Modifier,
    speed: Float = 1f,
) {
    val colors = LocalAuralisTheme.current.colors
    val reduceMotion = LocalReduceMotion.current
    val anchor = remember(positionMs, isPlaying, speed) { positionMs to SystemClock.uptimeMillis() }
    val latestAnchor by rememberUpdatedState(anchor)
    var now by remember { mutableStateOf(SystemClock.uptimeMillis()) }
    var layout by remember(text) { mutableStateOf<TextLayoutResult?>(null) }
    val timed = start != null && nextStart != null && nextStart > start
    LaunchedEffect(isCurrent, isPlaying, reduceMotion, animate, timed) {
        if (isCurrent && isPlaying && !reduceMotion && animate && timed) {
            while (true) {
                now = SystemClock.uptimeMillis()
                delay(33)
            }
        }
    }
    val ranges = remember(text) {
        val iterator = BreakIterator.getCharacterInstance().apply { setText(text) }
        buildList {
            var begin = iterator.first()
            var end = iterator.next()
            while (end != BreakIterator.DONE) {
                if (!text.substring(begin, end).all { it == '\n' || it == '\r' }) add(begin until end)
                begin = end
                end = iterator.next()
            }
        }
    }
    // Bounds are measured only when native text layout changes, never on the animation clock.
    val bounds = remember(layout, ranges) {
        layout?.let { measured -> ranges.map { range ->
            range.drop(1).fold(measured.getBoundingBox(range.first)) { rect, index ->
                val next = measured.getBoundingBox(index)
                androidx.compose.ui.geometry.Rect(
                    minOf(rect.left, next.left), minOf(rect.top, next.top),
                    maxOf(rect.right, next.right), maxOf(rect.bottom, next.bottom),
                )
            }
        } }.orEmpty()
    }
    Text(
        text = text,
        style = MaterialTheme.typography.titleLarge.copy(fontWeight = FontWeight.Bold),
        color = if (isCurrent) colors.accent else colors.secondaryText.copy(alpha = 0.62f),
        textAlign = TextAlign.Center,
        onTextLayout = { layout = it },
        modifier = modifier.widthIn(max = 600.dp).fillMaxWidth()
            .padding(horizontal = AuralisSpacing.large, vertical = 3.dp)
            .drawWithContent {
                val measured = layout
                if (!isCurrent || reduceMotion || measured == null) {
                    drawContent()
                } else {
                    // Read the clock in drawing, so 30fps never recomposes or measures the list.
                    val position = NowPlayingUiPolicy.interpolatedPositionMs(
                        latestAnchor.first, now - latestAnchor.second, isPlaying, speed,
                    )
                    val progress = NowPlayingUiPolicy.lineProgress(position / 1000.0, start, nextStart)
                    if (progress == null) {
                        withTransform({ scale(1.06f, 1.06f, center) }) { drawText(measured, color = colors.accent) }
                    } else {
                        bounds.forEachIndexed { index, rect ->
                            val scale = NowPlayingUiPolicy.characterScale(index, bounds.size, progress)
                            withTransform({ scale(scale, scale, Offset(rect.center.x, rect.center.y)) }) {
                                // Draw the shaped native paragraph through each grapheme's slot.
                                // This retains word wrapping and emoji instead of laying out letters.
                                clipRect(rect.left, rect.top, rect.right, rect.bottom) {
                                    drawText(measured, color = colors.accent)
                                }
                            }
                        }
                    }
                }
            },
    )
}
