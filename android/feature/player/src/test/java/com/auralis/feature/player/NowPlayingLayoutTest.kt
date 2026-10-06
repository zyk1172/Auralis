// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
package com.auralis.feature.player

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.PagerState
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.material3.Text
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsNotSelected
import androidx.compose.ui.test.assertIsSelected
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import androidx.compose.ui.unit.dp
import com.auralis.core.designsystem.AuralisTheme
import com.google.common.truth.Truth.assertThat
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.LooperMode

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
@LooperMode(LooperMode.Mode.PAUSED)
class NowPlayingLayoutTest {
    @get:Rule val compose = createComposeRule()

    @Test
    @Config(qualifiers = "w390dp-h844dp-port")
    fun `portrait player has dismiss handle and usable controls`() {
        var closed = false
        compose.setContent {
            AuralisTheme {
                NowPlayingChromeLayout(
                    page = PlayerTab.Player,
                    chromeHidden = false,
                    onClose = { closed = true },
                    artwork = { Text("Artwork") },
                    pageContent = { Box(Modifier.fillMaxSize().testTag("page")) },
                    controls = { _, _ -> Text("Controls", Modifier.testTag("controls")) },
                )
            }
        }
        compose.onNodeWithTag("player.portrait").assertIsDisplayed()
        compose.onNodeWithTag("controls").assertIsDisplayed()
        compose.onNodeWithTag("player.dismiss").performClick()
        assertThat(closed).isTrue()
    }

    @Test
    @Config(qualifiers = "w844dp-h390dp-land")
    fun `landscape places artwork left of lyrics and controls without overlap`() {
        compose.setContent {
            AuralisTheme {
                NowPlayingChromeLayout(
                    page = PlayerTab.Lyrics,
                    chromeHidden = false,
                    onClose = {},
                    artwork = { Box(Modifier.fillMaxSize()) },
                    pageContent = { Text("Lyrics", Modifier.testTag("lyricsContent")) },
                    controls = { _, _ ->
                        Box(Modifier.fillMaxWidth().height(180.dp).testTag("fullControls"))
                    },
                    pageFooter = { Box(Modifier.fillMaxWidth().height(44.dp).testTag("footer")) },
                )
            }
        }
        compose.onNodeWithTag("player.landscape").assertIsDisplayed()
        val artwork = compose.onNodeWithTag("player.artwork").fetchSemanticsNode().boundsInRoot
        val lyrics = compose.onNodeWithTag("lyricsContent").fetchSemanticsNode().boundsInRoot
        val footer = compose.onNodeWithTag("footer").fetchSemanticsNode().boundsInRoot
        assertThat(artwork.right).isAtMost(lyrics.left)
        assertThat(lyrics.bottom).isAtMost(footer.top)
        compose.onNodeWithTag("footer").assertIsDisplayed()
        compose.onNodeWithTag("fullControls").assertDoesNotExist()
    }

    @Test
    @Config(qualifiers = "w844dp-h390dp-land")
    fun `immersive lyrics keeps landscape artwork and hides dismiss handle`() {
        compose.setContent {
            AuralisTheme {
                NowPlayingChromeLayout(
                    page = PlayerTab.Lyrics,
                    chromeHidden = true,
                    onClose = {},
                    artwork = { Box(Modifier.fillMaxSize()) },
                    pageContent = { Text("Lyrics") },
                    controls = { _, _ -> Text("Full controls", Modifier.testTag("fullControls")) },
                    pageFooter = { Text("Track identity", Modifier.testTag("identity")) },
                )
            }
        }
        compose.onNodeWithTag("player.artwork").assertIsDisplayed()
        compose.onNodeWithTag("player.dismiss").assertDoesNotExist()
        compose.onNodeWithTag("identity").assertIsDisplayed()
        compose.onNodeWithTag("fullControls").assertDoesNotExist()
    }

    @Test
    @Config(qualifiers = "w844dp-h390dp-land")
    fun `landscape lyrics and queue leave the right column to their content`() {
        var page by mutableStateOf(PlayerTab.Lyrics)
        compose.setContent {
            AuralisTheme {
                NowPlayingChromeLayout(
                    page = page,
                    chromeHidden = false,
                    onClose = {},
                    artwork = { Box(Modifier.fillMaxSize()) },
                    pageContent = { Box(Modifier.fillMaxSize().testTag("secondaryContent")) },
                    controls = { _, _ ->
                        Box(Modifier.fillMaxWidth().height(260.dp).testTag("fullControls"))
                    },
                    pageFooter = { Box(Modifier.fillMaxWidth().height(44.dp).testTag("footer")) },
                )
            }
        }
        for (target in listOf(PlayerTab.Lyrics, PlayerTab.Queue)) {
            compose.runOnIdle { page = target }
            compose.onNodeWithTag("fullControls").assertDoesNotExist()
            compose.onNodeWithTag("footer").assertIsDisplayed()
            val content = compose.onNodeWithTag("secondaryContent").fetchSemanticsNode()
            assertThat(content.boundsInRoot.height / content.layoutInfo.density.density)
                .isAtLeast(220f)
        }
    }

    @Test
    fun `reduced motion navigation settles without advancing animation time`() {
        lateinit var pager: PagerState
        compose.setContent {
            AuralisTheme(reduceMotion = true) {
                pager = rememberPagerState(initialPage = PlayerTab.Player.ordinal) { 3 }
                val navigationScope = rememberCoroutineScope()
                Column {
                    HorizontalPager(pager, Modifier.fillMaxWidth().height(240.dp)) {
                        Text("Page $it")
                    }
                    PlayerPageNavigation(pager, navigationScope, onActivity = {})
                }
            }
        }
        compose.mainClock.autoAdvance = false
        compose.onNodeWithTag("player.lyrics").performClick()
        compose.runOnIdle {
            assertThat(pager.currentPage).isEqualTo(PlayerTab.Lyrics.ordinal)
            assertThat(pager.isScrollInProgress).isFalse()
        }
        compose.mainClock.advanceTimeByFrame()
        compose.onNodeWithTag("player.lyrics").performClick()
        compose.runOnIdle {
            assertThat(pager.currentPage).isEqualTo(PlayerTab.Player.ordinal)
            assertThat(pager.isScrollInProgress).isFalse()
        }
        compose.mainClock.autoAdvance = true
    }

    @Test
    fun `second tap during page animation cancels the old destination`() {
        lateinit var pager: PagerState
        compose.setContent {
            AuralisTheme {
                pager = rememberPagerState(initialPage = PlayerTab.Player.ordinal) { 3 }
                val navigationScope = rememberCoroutineScope()
                Column {
                    HorizontalPager(pager, Modifier.fillMaxWidth().height(240.dp)) {
                        Text("Page $it")
                    }
                    PlayerPageNavigation(pager, navigationScope, onActivity = {})
                }
            }
        }
        compose.mainClock.autoAdvance = false
        compose.onNodeWithTag("player.lyrics").performClick()
        compose.runOnIdle { assertThat(pager.targetPage).isEqualTo(PlayerTab.Lyrics.ordinal) }
        compose.mainClock.advanceTimeByFrame()
        compose.onNodeWithTag("player.lyrics").performClick()
        compose.mainClock.advanceTimeBy(2_000)
        compose.runOnIdle {
            assertThat(pager.currentPage).isEqualTo(PlayerTab.Player.ordinal)
            assertThat(pager.isScrollInProgress).isFalse()
        }
        compose.mainClock.autoAdvance = true
    }

    @Test
    @Config(qualifiers = "w844dp-h390dp-land")
    fun `landscape navigation finishes when the footer changes parents`() {
        lateinit var pager: PagerState
        compose.setContent {
            AuralisTheme {
                pager = rememberPagerState(initialPage = PlayerTab.Player.ordinal) { 3 }
                val navigationScope = rememberCoroutineScope()
                NowPlayingChromeLayout(
                    page = PlayerTab.entries[pager.currentPage],
                    chromeHidden = false,
                    onClose = {},
                    artwork = { Box(Modifier.fillMaxSize()) },
                    pageContent = {
                        HorizontalPager(pager, Modifier.fillMaxSize()) { Text("Page $it") }
                    },
                    controls = { _, _ ->
                        Column {
                            Box(Modifier.fillMaxWidth().height(180.dp))
                            PlayerPageNavigation(pager, navigationScope, onActivity = {})
                        }
                    },
                    pageFooter = { PlayerPageNavigation(pager, navigationScope, onActivity = {}) },
                )
            }
        }
        compose.onNodeWithTag("player.lyrics").performClick()
        compose.runOnIdle {
            assertThat(pager.currentPage).isEqualTo(PlayerTab.Lyrics.ordinal)
            assertThat(pager.currentPageOffsetFraction).isWithin(0.001f).of(0f)
            assertThat(pager.isScrollInProgress).isFalse()
        }
    }

    @Test
    fun `bottom buttons toggle to artwork on second tap`() {
        compose.setContent {
            AuralisTheme {
                var page by remember { mutableStateOf(PlayerTab.Player) }
                PlayerBottomNavigation(page) { page = NowPlayingUiPolicy.togglePage(page, it) }
            }
        }
        for (tag in listOf("player.lyrics", "player.queue")) {
            compose.onNodeWithTag(tag).performClick().assertIsSelected()
            compose.onNodeWithTag(tag).performClick().assertIsNotSelected()
        }
    }
}
