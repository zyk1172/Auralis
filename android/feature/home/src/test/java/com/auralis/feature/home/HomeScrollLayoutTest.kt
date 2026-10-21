// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
package com.auralis.feature.home

import androidx.compose.foundation.layout.Box
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.hasAnyAncestor
import androidx.compose.ui.test.hasScrollAction
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollToIndex
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import com.auralis.core.designsystem.AuralisTheme
import com.auralis.core.domain.AlbumId
import com.auralis.core.domain.ArtistId
import com.auralis.core.domain.HomeModuleId
import com.auralis.core.domain.ServerId
import com.auralis.core.domain.Track
import com.auralis.core.domain.TrackId
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
class HomeScrollLayoutTest {
    @get:Rule val compose = createComposeRule()

    @Test
    @Config(qualifiers = "w390dp-h844dp-port")
    fun `phone shelves reach the feed edges with inset first and last cards`() = verifyShelf()

    @Test
    @Config(qualifiers = "w1200dp-h800dp-land")
    fun `wide windows use the whole feed without stretching cards`() = verifyShelf()

    @Test
    @Config(qualifiers = "w1200dp-h800dp-land")
    fun `RTL shelves preserve both edge insets and playback indices`() = verifyShelf(rtl = true)

    @Test
    @Config(qualifiers = "w390dp-h844dp-port")
    fun `legacy home uses the same full width scrolling`() = verifyShelf(legacy = true)

    private fun verifyShelf(rtl: Boolean = false, legacy: Boolean = false) {
        val tracks = (0..23).map { index ->
            Track(
                id = TrackId("track-$index"), serverId = ServerId("layout"),
                albumId = AlbumId("album"), artistId = ArtistId("artist"),
                title = "Track $index", artistName = "Artist", albumTitle = "Album",
                durationSeconds = 180.0,
            )
        }
        val module = HomeModuleSnapshot(HomeModuleId.RandomSongs, tracks = tracks)
        var playedIndex: Int? = null
        compose.setContent {
            CompositionLocalProvider(LocalLayoutDirection provides
                if (rtl) LayoutDirection.Rtl else LayoutDirection.Ltr) {
                AuralisTheme {
                    HomeFeed(0.dp, 20.dp, Modifier.testTag("feed")) {
                        item {
                            Box(Modifier.testTag("module")) {
                                if (legacy) {
                                    HomeModuleSection(module, { _, index -> playedIndex = index }, {}, {})
                                } else {
                                    AppleModuleSection(module, { _, index -> playedIndex = index }, {}, {})
                                }
                            }
                        }
                    }
                }
            }
        }
        val feed = compose.onNodeWithTag("feed").fetchSemanticsNode().boundsInRoot
        val root = compose.onRoot().fetchSemanticsNode().boundsInRoot
        assertThat(feed.left).isWithin(1f).of(root.left)
        assertThat(feed.right).isWithin(1f).of(root.right)
        val shelf = compose.onNode(hasScrollAction().and(hasAnyAncestor(hasTestTag("module"))))
        val viewport = shelf.fetchSemanticsNode().boundsInRoot
        val inset = with(compose.density) { 20.dp.toPx() }
        val cardWidth = with(compose.density) { 140.dp.toPx() }
        assertThat(viewport.left).isWithin(1f).of(feed.left)
        assertThat(viewport.right).isWithin(1f).of(feed.right)
        val first = compose.onNodeWithText("Track 0").fetchSemanticsNode().boundsInRoot
        assertThat(first.width).isWithin(1f).of(cardWidth)
        assertThat(if (rtl) viewport.right - first.right else first.left - viewport.left)
            .isWithin(1f).of(inset)

        shelf.performScrollToIndex(tracks.lastIndex)
        val last = compose.onNodeWithText("Track 23").fetchSemanticsNode().boundsInRoot
        assertThat(if (rtl) last.left - viewport.left else viewport.right - last.right)
            .isWithin(1f).of(inset)
        compose.onNodeWithText("Track 23").performClick()
        assertThat(playedIndex).isEqualTo(23)
    }
}
