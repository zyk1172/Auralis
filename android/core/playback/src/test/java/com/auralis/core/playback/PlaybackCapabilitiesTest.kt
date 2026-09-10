// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.core.playback

import com.auralis.core.domain.AlbumId
import com.auralis.core.domain.ArtistId
import com.auralis.core.domain.PlayMode
import com.auralis.core.domain.QueueEntry
import com.auralis.core.domain.ServerId
import com.auralis.core.domain.Track
import com.auralis.core.domain.TrackId
import com.google.common.truth.Truth.assertThat
import org.junit.Test

class PlaybackCapabilitiesTest {
    private val track = Track(
        id = TrackId("t1"),
        serverId = ServerId("s1"),
        albumId = AlbumId("a1"),
        artistId = ArtistId("r1"),
        title = "Track",
        artistName = "Artist",
        albumTitle = "Album",
        durationSeconds = 180.0,
    )

    private fun playback(mode: PlayMode) = PlaybackSnapshot(track = track, playMode = mode)

    private fun queue(current: Int, total: Int) = QueueSnapshot(
        entries = listOf(QueueEntry.of(track)),
        currentLogicalIndex = current,
        currentWindowIndex = 0,
        totalCount = total,
    )

    @Test
    fun `previous is available whenever a current occurrence exists`() {
        assertThat(PlaybackCapabilities.canGoPrevious(playback(PlayMode.Sequential), queue(0, 1))).isTrue()
        assertThat(PlaybackCapabilities.canGoPrevious(playback(PlayMode.Sequential), queue(1, 3))).isTrue()
    }

    @Test
    fun `repeat all exposes wraparound next`() {
        assertThat(PlaybackCapabilities.canGoNext(playback(PlayMode.RepeatAll), queue(2, 3))).isTrue()
    }

    @Test
    fun `sequential next stops at physical queue end`() {
        assertThat(PlaybackCapabilities.canGoNext(playback(PlayMode.Sequential), queue(2, 3))).isFalse()
    }

    @Test
    fun `repeat one next restarts current occurrence`() {
        assertThat(PlaybackCapabilities.canGoNext(playback(PlayMode.RepeatOne), queue(0, 1))).isTrue()
    }

    @Test
    fun `shuffle requires a non-current candidate`() {
        assertThat(PlaybackCapabilities.canGoNext(playback(PlayMode.Shuffle), queue(0, 1))).isFalse()
        assertThat(PlaybackCapabilities.canGoNext(playback(PlayMode.Shuffle), queue(0, 2))).isTrue()
    }
}
