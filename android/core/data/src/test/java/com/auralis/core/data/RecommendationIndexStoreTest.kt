// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.core.data

import com.google.common.truth.Truth.assertThat
import com.auralis.core.data.db.TrackEntity
import com.auralis.core.data.repository.RecommendationIndexStore
import com.auralis.core.domain.AlbumId
import com.auralis.core.domain.ArtistId
import com.auralis.core.domain.RecommendationIndexClassificationInput
import com.auralis.core.domain.RecommendationIndexTag
import com.auralis.core.domain.ServerId
import com.auralis.core.domain.Track
import com.auralis.core.domain.TrackId
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.encodeToString
import org.junit.Test

class RecommendationIndexStoreTest : RoomDbTest() {
    private val server = ServerId("server-a")

    @Test
    fun invalidBatchDoesNotCommitAnyTrack() = runBlocking {
        val db = openDatabase()
        try {
            val first = track("track-1", "One")
            val second = track("track-2", "Two")
            db.trackDao().upsertAll(listOf(first.toEntity(), second.toEntity()))
            val store = RecommendationIndexStore(db)

            val error = runCatching {
                store.replaceClassifications(
                    serverId = server,
                    classifications = listOf(
                        RecommendationIndexClassificationInput(
                            first.globalId,
                            listOf(RecommendationIndexTag("mood", "mood.calm", 0.9)),
                        ),
                        RecommendationIndexClassificationInput(
                            second.globalId,
                            listOf(RecommendationIndexTag("mood", "unknown", 0.9)),
                        ),
                    ),
                )
            }.exceptionOrNull()

            assertThat(error).hasMessageThat().contains("未知 taxonomy")
            assertThat(store.status(server).indexedTracks).isEqualTo(0)
            assertThat(store.categories(server)).isEmpty()
        } finally {
            db.close()
        }
    }

    @Test
    fun changedTrackPayloadBecomesPendingAndIsRemovedFromCategories() = runBlocking {
        val db = openDatabase()
        try {
            val first = track("track-1", "One")
            val second = track("track-2", "Two")
            db.trackDao().upsertAll(listOf(first.toEntity(), second.toEntity()))
            val store = RecommendationIndexStore(db)
            val tag = RecommendationIndexTag("mood", "mood.calm", 0.9)
            store.replaceClassifications(
                server,
                listOf(
                    RecommendationIndexClassificationInput(first.globalId, listOf(tag)),
                    RecommendationIndexClassificationInput(second.globalId, listOf(tag)),
                ),
            )

            assertThat(store.status(server).indexedTracks).isEqualTo(2)
            assertThat(store.categories(server).single().trackCount).isEqualTo(2)

            db.trackDao().upsertAll(listOf(track("track-1", "One (Remastered)").toEntity()))

            val status = store.status(server)
            assertThat(status.indexedTracks).isEqualTo(1)
            assertThat(status.pendingTracks).isEqualTo(1)
            assertThat(store.categories(server).single().trackCount).isEqualTo(1)
        } finally {
            db.close()
        }
    }

    @Test
    fun categoryTracksAreRankedByConfidenceThenTitle() = runBlocking {
        val db = openDatabase()
        try {
            val beta = track("track-1", "Beta")
            val alpha = track("track-2", "Alpha")
            val gamma = track("track-3", "Gamma")
            db.trackDao().upsertAll(listOf(beta.toEntity(), alpha.toEntity(), gamma.toEntity()))
            val store = RecommendationIndexStore(db)
            store.replaceClassifications(
                server,
                listOf(
                    RecommendationIndexClassificationInput(beta.globalId, listOf(RecommendationIndexTag("mood", "mood.calm", 0.4))),
                    RecommendationIndexClassificationInput(alpha.globalId, listOf(RecommendationIndexTag("mood", "mood.calm", 0.9))),
                    RecommendationIndexClassificationInput(gamma.globalId, listOf(RecommendationIndexTag("mood", "mood.calm", 0.9))),
                ),
            )

            assertThat(store.tracksForCategory(server, "mood", "mood.calm", 10).map { it.id.value })
                .containsExactly("track-2", "track-3", "track-1")
                .inOrder()
        } finally {
            db.close()
        }
    }

    private fun track(remoteId: String, title: String): Track = Track(
        id = TrackId(remoteId),
        serverId = server,
        albumId = AlbumId("album-1"),
        artistId = ArtistId("artist-1"),
        title = title,
        artistName = "Artist",
        albumTitle = "Album",
        durationSeconds = 180.0,
    )

    private fun Track.toEntity(): TrackEntity = TrackEntity(
        globalId = globalId.serialized,
        serverId = serverId.value,
        remoteId = id.value,
        title = title,
        artistName = artistName,
        albumTitle = albumTitle,
        albumGid = albumId.value,
        artistGid = artistId.value,
        duration = durationSeconds,
        year = year,
        payload = com.auralis.core.data.db.DataJson.json.encodeToString(this),
        updatedAt = System.currentTimeMillis(),
    )
}
