// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.feature.assistant

import com.google.common.truth.Truth.assertThat
import com.auralis.core.domain.AlbumId
import com.auralis.core.domain.ArtistId
import com.auralis.core.domain.RecommendationIndexBatch
import com.auralis.core.domain.ServerId
import com.auralis.core.domain.Track
import com.auralis.core.domain.TrackId
import org.junit.Test

class RecommendationIndexResponseParserTest {
    private val server = ServerId("server-a")
    private val tracks = listOf(
        Track(
            id = TrackId("track-1"),
            serverId = server,
            albumId = AlbumId("album-1"),
            artistId = ArtistId("artist-1"),
            title = "One",
            artistName = "Artist",
            albumTitle = "Album",
            durationSeconds = 180.0,
        ),
        Track(
            id = TrackId("track-2"),
            serverId = server,
            albumId = AlbumId("album-1"),
            artistId = ArtistId("artist-1"),
            title = "Two",
            artistName = "Artist",
            albumTitle = "Album",
            durationSeconds = 200.0,
        ),
    )

    private val batch = RecommendationIndexBatch(
        serverId = server,
        tracks = tracks,
        totalTracks = 2,
        indexedTracks = 0,
        pendingTracks = 2,
    )

    @Test
    fun parsesOnlyKnownTagsAndNumericFeatures() {
        val result = RecommendationIndexResponseParser().parse(
            """{"items":[
                {"id":"server-a:track-1","tags":["mood.calm","not-a-tag"],"features":{"energy":8,"tempo":2,"invalid":99},"confidence":0.9},
                {"id":"server-a:track-2","tags":[],"features":{"energy":11,"valence":3},"confidence":0.7}
            ]}""",
            batch,
        )

        assertThat(result).hasSize(2)
        assertThat(result[0].globalId.serialized).isEqualTo("server-a:track-1")
        assertThat(result[0].tags.map { it.dimension to it.value }).containsExactly(
            "mood" to "mood.calm",
            "energy" to "8",
            "tempo" to "2",
        )
        assertThat(result[1].tags.map { it.dimension to it.value }).containsExactly("valence" to "3")
    }

    @Test
    fun rejectsPartialBatchBeforeCommit() {
        val error = runCatching {
            RecommendationIndexResponseParser().parse(
                """{"items":[{"id":"server-a:track-1","tags":[] }]}""",
                batch,
            )
        }.exceptionOrNull()

        assertThat(error).hasMessageThat().contains("未完整覆盖")
    }

    @Test
    fun rejectsForeignOrDuplicateIds() {
        val foreign = runCatching {
            RecommendationIndexResponseParser().parse(
                """{"items":[{"id":"server-b:track-1"},{"id":"server-a:track-2"}]}""",
                batch,
            )
        }.exceptionOrNull()
        assertThat(foreign).hasMessageThat().contains("当前 batch 之外")

        val duplicate = runCatching {
            RecommendationIndexResponseParser().parse(
                """{"items":[{"id":"server-a:track-1"},{"id":"server-a:track-1"}]}""",
                batch,
            )
        }.exceptionOrNull()
        assertThat(duplicate).hasMessageThat().contains("重复 id")
    }
}
