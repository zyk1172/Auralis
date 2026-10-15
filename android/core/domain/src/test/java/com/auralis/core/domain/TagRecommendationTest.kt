// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
package com.auralis.core.domain

import com.google.common.truth.Truth.assertThat
import org.junit.Assert.assertThrows
import org.junit.Test

class TagRecommendationTest {
    private fun candidate(id: String, tags: List<String>, artist: String = id, album: String = "", confidence: Double = 0.9) =
        TagRecommendationCandidate(Track(TrackId(id), ServerId("server"), AlbumId("album-$id"), ArtistId("artist-$id"),
            "Song $id", artist, album, 180.0), tags.associateWith { confidence })

    @Test fun multipleDimensionsOutrankOnlyOne() {
        val full = candidate("full", listOf("scene.late_night", "instrument.piano"))
        val partial = candidate("partial", listOf("scene.late_night"), confidence = 1.0)
        val result = TagRecommendationRanker.recommend(listOf(partial, full), TagRecommendationQuery(preferTags = listOf("scene.late_night", "instrument.piano")))
        assertThat(result.first().track.id.value).isEqualTo("full")
        assertThat(result.first().matchedTags).containsExactly("scene.late_night", "instrument.piano")
    }

    @Test fun preferencesRemainSoftWhenHardIntentMatches() {
        val full = candidate("full", listOf("mood.calm", "instrument.piano"))
        val allowed = candidate("allowed", listOf("mood.calm"))
        val result = TagRecommendationRanker.recommend(listOf(allowed, full),
            TagRecommendationQuery(includeTags = listOf("mood.calm"), preferTags = listOf("instrument.piano")))
        assertThat(result.map { it.track.id.value }).containsExactly("full", "allowed").inOrder()
    }

    @Test fun hardIncludesExcludesAndNumericRangesNeverRelax() {
        val good = candidate("good", listOf("scene.late_night", "instrument.piano")).copy(numericFeatures = mapOf("energy" to 3))
        val sad = candidate("sad", listOf("scene.late_night", "instrument.piano", "mood.sad")).copy(numericFeatures = mapOf("energy" to 3))
        val partial = candidate("partial", listOf("scene.late_night")).copy(numericFeatures = mapOf("energy" to 3))
        val query = TagRecommendationQuery(includeTags = listOf("scene.late_night", "instrument.piano"), excludeTags = listOf("mood.sad"), numericRanges = mapOf("energy" to 1..4))
        assertThat(TagRecommendationRanker.recommend(listOf(good, sad, partial), query).map { it.track.id.value }).containsExactly("good")
        assertThat(TagRecommendationRanker.recommend(listOf(good, sad, partial), TagRecommendationQuery(numericRanges = mapOf("energy" to 8..10)))).isEmpty()
    }

    @Test fun noRandomPaddingAndInvalidIntentFails() {
        val weak = candidate("weak", listOf("mood.calm"), confidence = 0.2)
        val other = candidate("other", listOf("mood.sad"))
        assertThat(TagRecommendationRanker.recommend(listOf(weak, other), TagRecommendationQuery(preferTags = listOf("mood.calm")))).isEmpty()
        assertThrows(IllegalArgumentException::class.java) { TagRecommendationQuery().validated() }
        assertThrows(IllegalArgumentException::class.java) { TagRecommendationQuery(includeTags = listOf("unknown")).validated() }
        assertThrows(IllegalArgumentException::class.java) { TagRecommendationQuery(excludeTags = listOf("mood.sad")).validated() }
        assertThrows(IllegalArgumentException::class.java) { TagRecommendationQuery(preferTags = listOf("温暖")).validated() }
    }

    @Test fun diversityBudgetsIncludeCollisionSeeds() {
        val seed = candidate("seed", listOf("mood.calm"), "Artist A", "Album")
        val same = candidate("same", listOf("mood.calm"), "Artist A", "Album")
        val other = candidate("other", listOf("mood.calm"), "Artist B")
        val result = TagRecommendationRanker.recommend(listOf(seed, same, other),
            TagRecommendationQuery(preferTags = listOf("mood.calm"), maxPerArtist = 3, maxPerAlbum = 1), listOf(seed.track))
        assertThat(result.map { it.track.id.value }).containsExactly("other")
    }

    @Test fun exclusionsAreGlobalAndTiesAreStable() {
        val a = candidate("a", listOf("mood.calm"))
        val b = candidate("b", listOf("mood.calm"))
        val query = TagRecommendationQuery(preferTags = listOf("mood.calm"), excludedTrackIds = setOf("other:a"))
        assertThat(TagRecommendationRanker.recommend(listOf(a, b), query).map { it.track.id }).containsExactlyElementsIn(
            TagRecommendationRanker.recommend(listOf(b, a), query).map { it.track.id }).inOrder()
        assertThat(TagRecommendationRanker.recommend(listOf(a, b), query.copy(excludedTrackIds = setOf("server:a"))).map { it.track.id.value }).containsExactly("b")
    }

    @Test fun sameRecordingDeduplicatesButDifferentDurationDoesNot() {
        val first = candidate("a", listOf("mood.calm"))
        val duplicate = first.copy(track = first.track.copy(id = TrackId("duplicate")))
        val live = first.copy(track = first.track.copy(id = TrackId("live"), durationSeconds = 300.0))
        assertThat(TagRecommendationRanker.recommend(listOf(first, duplicate, live), TagRecommendationQuery(preferTags = listOf("mood.calm")))).hasSize(2)
    }
}
