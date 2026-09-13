// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.feature.assistant

import com.auralis.core.domain.AlbumId
import com.auralis.core.domain.ArtistId
import com.auralis.core.domain.GlobalId
import com.auralis.core.domain.ServerId
import com.auralis.core.domain.Track
import com.auralis.core.domain.TrackId
import com.google.common.truth.Truth.assertThat
import org.junit.Test

class SemanticCollisionMatcherTest {
    private val server = ServerId("server")

    private fun track(id: String, title: String, artist: String, album: String = "Album") = Track(
        id = TrackId(id),
        serverId = server,
        albumId = AlbumId("album-$id"),
        artistId = ArtistId("artist-$artist"),
        title = title,
        artistName = artist,
        albumTitle = album,
        durationSeconds = 200.0,
    )

    @Test fun remasterNormalizesToRealTrack() {
        val result = SemanticCollisionMatcher.match(
            candidates = listOf(SemanticRecommendationCandidate("Something", "The Beatles")),
            tracks = listOf(track("1", "Something - Remastered 2009", "The Beatles")),
            targetCount = 1,
        )
        assertThat(result.map { it.id.value }).containsExactly("1")
    }

    @Test fun wrongArtistDoesNotCollide() {
        val result = SemanticCollisionMatcher.match(
            candidates = listOf(SemanticRecommendationCandidate("Hello", "Lionel Richie")),
            tracks = listOf(track("1", "Hello", "Adele")),
            targetCount = 1,
        )
        assertThat(result).isEmpty()
    }

    @Test fun titleOnlyAmbiguityIsRejected() {
        val result = SemanticCollisionMatcher.match(
            candidates = listOf(SemanticRecommendationCandidate("Home")),
            tracks = listOf(track("1", "Home", "A"), track("2", "Home", "B")),
            targetCount = 1,
        )
        assertThat(result).isEmpty()
    }

    @Test fun localDislikeDedupAndArtistLimitAreEnforced() {
        val one = track("1", "One", "A")
        val two = track("2", "Two", "A")
        val three = track("3", "Three", "B")
        val result = SemanticCollisionMatcher.match(
            candidates = listOf(
                SemanticRecommendationCandidate("One", "A"),
                SemanticRecommendationCandidate("Two", "A"),
                SemanticRecommendationCandidate("Two", "A"),
                SemanticRecommendationCandidate("Three", "B"),
            ),
            tracks = listOf(one, two, three),
            disliked = setOf(GlobalId(server, "1")),
            targetCount = 3,
            maxPerArtist = 1,
        )
        assertThat(result.map { it.id.value }).containsExactly("2", "3").inOrder()
    }
}
