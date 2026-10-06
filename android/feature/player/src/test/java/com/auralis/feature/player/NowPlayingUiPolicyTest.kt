// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
package com.auralis.feature.player

import com.google.common.truth.Truth.assertThat
import org.junit.Test

class NowPlayingUiPolicyTest {
    @Test
    fun `window geometry chooses layout including narrow split screen`() {
        assertThat(NowPlayingUiPolicy.usesLandscape(390f, 844f)).isFalse()
        assertThat(NowPlayingUiPolicy.usesLandscape(844f, 390f)).isTrue()
        assertThat(NowPlayingUiPolicy.usesLandscape(1024f, 768f)).isTrue()
        assertThat(NowPlayingUiPolicy.usesLandscape(500f, 390f)).isFalse()
        assertThat(NowPlayingUiPolicy.usesLandscape(844f, 0f)).isFalse()
    }

    @Test
    fun `artwork fits short windows and tablet cap`() {
        assertThat(NowPlayingUiPolicy.landscapeArtworkSide(844f, 390f, false))
            .isWithin(0.001f)
            .of(304.2f)
        assertThat(NowPlayingUiPolicy.landscapeArtworkSide(1366f, 1024f, true)).isEqualTo(520f)
        assertThat(NowPlayingUiPolicy.landscapeArtworkSide(600f, 160f, false)).isAtMost(160f)
    }

    @Test
    fun `second tap on lyrics or queue returns to artwork`() {
        for (target in listOf(PlayerTab.Lyrics, PlayerTab.Queue)) {
            assertThat(NowPlayingUiPolicy.togglePage(PlayerTab.Player, target)).isEqualTo(target)
            assertThat(NowPlayingUiPolicy.togglePage(target, target)).isEqualTo(PlayerTab.Player)
        }
    }

    @Test
    fun `paused artwork shrinks without changing measured dimensions`() {
        assertThat(NowPlayingUiPolicy.artworkScale(true)).isEqualTo(1f)
        assertThat(NowPlayingUiPolicy.artworkScale(false)).isEqualTo(0.82f)
    }

    @Test
    fun `lyrics ignores short and horizontal swipes`() {
        assertThat(NowPlayingUiPolicy.lyricsAutoHideDelayMs).isEqualTo(5_000)
        assertThat(NowPlayingUiPolicy.lyricsHiddenForSwipe(0f, -44f)).isTrue()
        assertThat(NowPlayingUiPolicy.lyricsHiddenForSwipe(0f, 44f)).isFalse()
        assertThat(NowPlayingUiPolicy.lyricsHiddenForSwipe(60f, -44f)).isNull()
        assertThat(NowPlayingUiPolicy.lyricsHiddenForSwipe(0f, -43f)).isNull()
    }

    @Test
    fun `line animation interpolates only when next timestamp exists`() {
        assertThat(NowPlayingUiPolicy.lineProgress(15.0, 10.0, 20.0)).isEqualTo(0.5f)
        assertThat(NowPlayingUiPolicy.lineProgress(0.0, 10.0, 20.0)).isEqualTo(0f)
        assertThat(NowPlayingUiPolicy.lineProgress(25.0, 10.0, 20.0)).isEqualTo(1f)
        assertThat(NowPlayingUiPolicy.lineProgress(15.0, 10.0, null)).isNull()
        assertThat(NowPlayingUiPolicy.lineProgress(15.0, 10.0, 10.0)).isNull()
        assertThat(NowPlayingUiPolicy.characterScale(2, 5, 0.5f)).isWithin(0.001f).of(1.12f)
        assertThat(NowPlayingUiPolicy.characterScale(0, 5, 0.5f)).isEqualTo(1.02f)
    }
}
