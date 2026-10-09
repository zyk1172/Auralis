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
            .of(342f)
        assertThat(NowPlayingUiPolicy.landscapeArtworkSide(1366f, 1024f, true)).isEqualTo(600f)
        assertThat(NowPlayingUiPolicy.landscapeArtworkSide(600f, 160f, false)).isAtMost(160f)
    }

    @Test
    fun `landscape keeps margins and a usable control column`() {
        for (tablet in listOf(false, true)) {
            for ((width, height) in listOf(844f to 390f, 600f to 160f, 1194f to 834f, 1366f to 1024f)) {
                val side = NowPlayingUiPolicy.landscapeArtworkSide(width, height, tablet)
                val content = width - 2 * NowPlayingUiPolicy.landscapeHorizontalPadding(tablet) -
                    NowPlayingUiPolicy.landscapeColumnSpacing(tablet)
                assertThat(side).isAtMost(content * 0.5f)
                assertThat(side).isAtMost(height - if (tablet) 64f else 48f)
            }
        }
        assertThat(NowPlayingUiPolicy.landscapeArtworkSide(1194f, 834f, true)).isEqualTo(547f)
        assertThat(NowPlayingUiPolicy.landscapeArtworkSide(10f, 20f, false)).isEqualTo(0f)
    }

    @Test
    fun `sung characters stay at one point one and subsequent characters join smoothly`() {
        for (progress in listOf(0.25f, 0.5f, 0.75f, 1f)) {
            assertThat(NowPlayingUiPolicy.characterScale(1, 5, progress)).isWithin(0.0001f).of(1.1f)
        }
        assertThat(NowPlayingUiPolicy.characterScale(2, 5, 0.375f)).isWithin(0.0001f).of(1.06f)
        for (index in 0 until 5) {
            assertThat(NowPlayingUiPolicy.characterScale(index, 5, 1f)).isWithin(0.0001f).of(1.1f)
        }
        assertThat(NowPlayingUiPolicy.characterScale(0, 1, 0.5f)).isWithin(0.0001f).of(1.1f)
        assertThat(NowPlayingUiPolicy.characterScale(0, 5, null)).isEqualTo(1.06f)
        assertThat(NowPlayingUiPolicy.characterScale(0, 0, 1f)).isEqualTo(1f)
    }

    @Test
    fun `follow resumes only after user motion ends`() {
        val state = LyricsScrollFollowState()
        assertThat(state.isFollowingPlayback).isTrue()
        state.beginUserScroll()
        state.resumeFollowing()
        assertThat(state.isFollowingPlayback).isFalse()
        state.endUserScroll()
        assertThat(state.isFollowingPlayback).isFalse()
        state.resumeFollowing()
        assertThat(state.isFollowingPlayback).isTrue()
        assertThat(NowPlayingUiPolicy.lyricsFollowResumeDelayMs).isEqualTo(5_000L)
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
    fun `lyric interpolation respects playback speed pause and stalled publications`() {
        assertThat(NowPlayingUiPolicy.interpolatedPositionMs(1000, 100, true, 2f)).isEqualTo(1200)
        assertThat(NowPlayingUiPolicy.interpolatedPositionMs(1000, 100, true, 0.5f)).isEqualTo(1050)
        assertThat(NowPlayingUiPolicy.interpolatedPositionMs(1000, 100, false, 2f)).isEqualTo(1000)
        assertThat(NowPlayingUiPolicy.interpolatedPositionMs(1000, 5000, true, 1f)).isEqualTo(1750)
        assertThat(NowPlayingUiPolicy.interpolatedPositionMs(1000, -100, true, 1f)).isEqualTo(1000)
    }

    @Test
    fun `line animation interpolates only when next timestamp exists`() {
        assertThat(NowPlayingUiPolicy.lineProgress(15.0, 10.0, 20.0)).isEqualTo(0.5f)
        assertThat(NowPlayingUiPolicy.lineProgress(0.0, 10.0, 20.0)).isEqualTo(0f)
        assertThat(NowPlayingUiPolicy.lineProgress(25.0, 10.0, 20.0)).isEqualTo(1f)
        assertThat(NowPlayingUiPolicy.lineProgress(15.0, 10.0, null)).isNull()
        assertThat(NowPlayingUiPolicy.lineProgress(15.0, 10.0, 10.0)).isNull()
        assertThat(NowPlayingUiPolicy.characterScale(2, 5, 0.5f)).isWithin(0.001f).of(1.1f)
        assertThat(NowPlayingUiPolicy.characterScale(4, 5, 0.5f)).isEqualTo(1.02f)
    }
}
