// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
package com.auralis.feature.player

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.assertTextEquals
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.test.swipeUp
import androidx.compose.ui.unit.dp
import com.auralis.core.designsystem.AuralisTheme
import com.auralis.core.domain.GlobalId
import com.auralis.core.domain.LyricsDocument
import com.auralis.core.domain.TimedLyricLine
import com.google.common.truth.Truth.assertThat
import org.junit.Rule
import org.junit.Test

abstract class LyricsUiTestCases {
    @get:Rule val compose = createComposeRule()

    protected open fun recordFrame(name: String) = Unit

    @Test
    fun mixedScriptLyricsKeepLayoutAndSemantics() {
        val text = "逐字放大的歌词 stays shaped 👩‍👩‍👧‍👦 café e\u0301 — a long line with spaces 换行依旧稳定"
        val current = mutableStateOf(false)
        val position = mutableStateOf(2_500L)
        val reduced = mutableStateOf(false)
        compose.setContent {
            AuralisTheme(reduceMotion = reduced.value) {
                Box(Modifier.width(280.dp)) {
                    AnimatedLyricLine(text, current.value, false, false, position.value,
                        0.0, 10.0, Modifier.testTag("line"))
                }
            }
        }
        recordFrame("lyrics-inactive")
        val original = compose.onNodeWithTag("line").fetchSemanticsNode().boundsInRoot
        for ((active, time, reduce) in listOf(
            Triple(true, 2_500L, false), Triple(true, 7_500L, false),
            Triple(true, 10_000L, false), Triple(false, 10_000L, false), Triple(true, 5_000L, true),
        )) {
            compose.runOnIdle { current.value = active; position.value = time; reduced.value = reduce }
            compose.onNodeWithTag("line").assertTextEquals(text)
            assertThat(compose.onNodeWithTag("line").fetchSemanticsNode().boundsInRoot).isEqualTo(original)
            recordFrame("lyrics-$active-$time-$reduce")
        }
    }

    @Test
    fun manualBrowsingResumesLatestLineAfterFiveIdleSeconds() {
        val doc = LyricsDocument(
            globalId = GlobalId(com.auralis.core.domain.ServerId("fixture"), "lyrics"),
            lines = (0 until 60).map { TimedLyricLine(startTimeSeconds = it * 10.0, text = "歌词 Line $it") },
            isSynced = true,
        )
        val position = mutableStateOf(100_000L)
        val follow = LyricsScrollFollowState()
        lateinit var list: LazyListState
        compose.setContent {
            AuralisTheme(reduceMotion = true) {
                list = rememberLazyListState()
                Box(Modifier.width(390.dp).height(500.dp)) {
                    SyncedLyricsContent(doc, position.value, false, true, follow, list)
                }
            }
        }
        compose.waitForIdle()
        compose.mainClock.autoAdvance = false
        compose.onNodeWithTag("player.lyricsScroll").performTouchInput { swipeUp(durationMillis = 600) }
        compose.mainClock.advanceTimeBy(1_500)
        var held: Pair<Int, Int>? = null
        compose.runOnIdle {
            assertThat(follow.isUserScrolling).isFalse()
            assertThat(follow.isFollowingPlayback).isFalse()
            held = list.firstVisibleItemIndex to list.firstVisibleItemScrollOffset
            position.value = 250_000L
        }
        compose.mainClock.advanceTimeBy(2_000)
        compose.runOnIdle {
            assertThat(list.firstVisibleItemIndex to list.firstVisibleItemScrollOffset).isEqualTo(held)
            assertThat(follow.isFollowingPlayback).isFalse()
        }
        compose.mainClock.advanceTimeBy(5_100)
        compose.runOnIdle {
            assertThat(follow.isFollowingPlayback).isTrue()
            val latest = list.layoutInfo.visibleItemsInfo.first { it.index == 25 }
            assertThat(kotlin.math.abs(latest.offset + latest.size / 2 - list.layoutInfo.viewportSize.height / 2))
                .isAtMost(30)
        }
        compose.mainClock.autoAdvance = true
    }
}
