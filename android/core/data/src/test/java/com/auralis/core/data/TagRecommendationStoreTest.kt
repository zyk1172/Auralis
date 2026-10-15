// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
package com.auralis.core.data

import com.auralis.core.data.db.DataJson
import com.auralis.core.data.db.DislikedTrackEntity
import com.auralis.core.data.db.TrackEntity
import com.auralis.core.data.repository.RecommendationIndexStore
import com.auralis.core.domain.*
import com.google.common.truth.Truth.assertThat
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.encodeToString
import org.junit.Test

class TagRecommendationStoreTest : RoomDbTest() {
    @Test fun multiLabelRecordsSupportAlternativeGroupsAfterPersistence() = runBlocking<Unit> {
        val db = openDatabase()
        try {
            val tracks = listOf(track("multi"), track("partial"), track("alternative"))
            db.trackDao().upsertAll(tracks.map { it.entity() })
            val store = RecommendationIndexStore(db)
            val labels = listOf(
                listOf("scene.study", "scene.focus", "scene.pomodoro", "instrument.piano", "instrument.oboe"),
                listOf("scene.study", "instrument.oboe"),
                listOf("scene.late_night", "instrument.acoustic_guitar"),
            )
            store.replaceClassifications(server, tracks.zip(labels).map { (track, tags) ->
                RecommendationIndexClassificationInput(track.globalId, tags.map { RecommendationIndexTag(it.substringBefore('.'), it, 0.9) })
            })
            val result = store.recommendByTags(server, TagRecommendationQuery(anyTagGroups = listOf(
                listOf("自习", "钢琴"), listOf("深夜", "木吉他"), listOf("番茄工作法", "双簧管"))))
            assertThat(result.map { it.track.id.value }).containsExactly("multi", "alternative")
            assertThat(result.first { it.track.id.value == "multi" }.matchedTags).containsAtLeast("scene.study", "scene.pomodoro", "instrument.piano", "instrument.oboe")
        } finally { db.close() }
    }
    private val server = ServerId("server")
    private fun track(id: String) = Track(TrackId(id), server, AlbumId(id), ArtistId(id), "Song $id", "Artist $id", "Album $id", 180.0)
    private fun Track.entity() = TrackEntity(globalId.serialized, serverId.value, id.value, title, artistName, albumTitle,
        albumId.value, artistId.value, durationSeconds, year, DataJson.json.encodeToString(this), 1)

    @Test fun recommendationsExcludeStaleDislikedAndOtherServerEntries() = runBlocking {
        val db = openDatabase()
        try {
            val tracks = listOf(track("good"), track("stale"), track("disliked"))
            db.trackDao().upsertAll(tracks.map { it.entity() })
            val store = RecommendationIndexStore(db)
            store.replaceClassifications(server, tracks.map { RecommendationIndexClassificationInput(it.globalId,
                listOf(RecommendationIndexTag("mood", "mood.calm", 0.9), RecommendationIndexTag("instrument", "instrument.piano", 0.9))) })
            db.trackDao().upsertAll(listOf(tracks[1].copy(title = "Changed title").entity()))
            db.annotationDao().upsertDislike(DislikedTrackEntity(tracks[2].globalId.serialized, server.value, 1, "test"))
            val query = TagRecommendationQuery(includeTags = listOf("mood.calm"), preferTags = listOf("instrument.piano"))
            assertThat(store.recommendByTags(server, query).map { it.track.id.value }).containsExactly("good")
            assertThat(store.recommendByTags(ServerId("other"), query)).isEmpty()
        } finally { db.close() }
    }

    @Test fun candidateLoadingChunksSqliteBindingsBeyondNineHundredTracks() = runBlocking {
        val db = openDatabase()
        try {
            val tracks = (0..904).map { track("$it") }
            db.trackDao().upsertAll(tracks.map { it.entity() })
            val store = RecommendationIndexStore(db)
            tracks.chunked(100).forEach { batch -> store.replaceClassifications(server, batch.map {
                RecommendationIndexClassificationInput(it.globalId, listOf(RecommendationIndexTag("mood", "mood.calm", 0.9)))
            }) }
            assertThat(store.recommendationCandidates(server)).hasSize(905)
        } finally { db.close() }
    }
}
