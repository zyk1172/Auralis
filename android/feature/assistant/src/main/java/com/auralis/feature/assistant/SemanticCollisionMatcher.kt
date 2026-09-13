// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.feature.assistant

import com.auralis.core.domain.GlobalId
import com.auralis.core.domain.Track
import java.text.Normalizer
import java.util.Locale
import kotlin.math.max
import kotlin.math.min

internal data class SemanticRecommendationCandidate(
    val title: String,
    val artist: String? = null,
    val album: String? = null,
)

/**
 * Android 手机/TV 共用的开放世界候选 -> 本地真实曲库 grounding。
 * 模型只负责候选召回；存在性、歧义、不喜欢、去重和艺人多样性全部由本地决定。
 */
internal object SemanticCollisionMatcher {
    private data class IndexedTrack(
        val track: Track,
        val title: String,
        val baseTitle: String,
        val artist: String,
        val album: String,
    )

    private data class Scored(val track: Track, val score: Double)

    fun match(
        candidates: List<SemanticRecommendationCandidate>,
        tracks: List<Track>,
        disliked: Set<GlobalId> = emptySet(),
        targetCount: Int,
        maxPerArtist: Int = 2,
    ): List<Track> {
        val target = targetCount.coerceIn(1, 100)
        val artistLimit = maxPerArtist.coerceIn(1, 10)
        val index = tracks.mapNotNull { track ->
            if (track.globalId in disliked) return@mapNotNull null
            val title = normalize(track.title)
            if (title.isBlank()) return@mapNotNull null
            IndexedTrack(
                track = track,
                title = title,
                baseTitle = baseTitle(track.title),
                artist = normalizeArtist(track.artistName),
                album = normalize(track.albumTitle),
            )
        }

        val result = mutableListOf<Track>()
        val seen = mutableSetOf<GlobalId>()
        val artistCounts = mutableMapOf<String, Int>()
        for (candidate in candidates.take(200)) {
            if (result.size >= target) break
            val resolved = bestMatch(candidate, index) ?: continue
            if (!seen.add(resolved.globalId)) continue
            val artistKey = normalizeArtist(resolved.artistName)
            if (artistCounts.getOrDefault(artistKey, 0) >= artistLimit) continue
            artistCounts[artistKey] = artistCounts.getOrDefault(artistKey, 0) + 1
            result += resolved
        }
        return result
    }

    private fun bestMatch(candidate: SemanticRecommendationCandidate, index: List<IndexedTrack>): Track? {
        val wantedTitle = normalize(candidate.title)
        if (wantedTitle.isBlank()) return null
        val wantedBase = baseTitle(candidate.title)
        val wantedArtist = candidate.artist?.let(::normalizeArtist)?.takeIf { it.isNotBlank() }
        val wantedAlbum = candidate.album?.let(::normalize)?.takeIf { it.isNotBlank() }

        val scored = buildList {
            index.forEach { item ->
                val titleExact = wantedTitle == item.title
                val baseExact = wantedBase.isNotBlank() && wantedBase == item.baseTitle
                val titleSimilarity = similarity(wantedTitle, item.title)
                if (wantedArtist == null) {
                    if (titleExact) add(Scored(item.track, 70.0 + if (wantedAlbum == item.album) 8.0 else 0.0))
                    return@forEach
                }
                if (!titleExact && !baseExact && titleSimilarity < 0.90) return@forEach
                val artistSimilarity = similarity(wantedArtist, item.artist)
                val artistStrong = wantedArtist == item.artist ||
                    item.artist.contains(wantedArtist) || wantedArtist.contains(item.artist) || artistSimilarity >= 0.86
                if (!artistStrong) return@forEach
                val titleScore = when {
                    titleExact -> 70.0
                    baseExact -> 64.0
                    else -> titleSimilarity * 60.0
                }
                val artistScore = when {
                    wantedArtist == item.artist -> 30.0
                    item.artist.contains(wantedArtist) || wantedArtist.contains(item.artist) -> 26.0
                    else -> artistSimilarity * 24.0
                }
                add(Scored(item.track, titleScore + artistScore + if (wantedAlbum == item.album) 8.0 else 0.0))
            }
        }.sortedWith(
            compareByDescending<Scored> { it.score }
                .thenBy { it.track.artistName.lowercase(Locale.ROOT) }
                .thenBy { it.track.albumTitle.lowercase(Locale.ROOT) }
                .thenBy { it.track.id.value }
        )
        if (scored.isEmpty()) return null
        if (wantedArtist == null && wantedAlbum == null && scored.size > 1) return null
        return scored.first().track
    }

    private fun normalizeArtist(raw: String): String {
        var value = normalize(raw)
        listOf(" feat ", " featuring ", " ft ").firstOrNull { value.contains(it) }?.let { marker ->
            value = value.substringBefore(marker).trim()
        }
        return value
    }

    private fun baseTitle(raw: String): String {
        var value = normalize(raw)
        val patterns = listOf(
            Regex("\\s+\\d{4}\\s+remaster(?:ed)?$"),
            Regex("\\s+remaster(?:ed)?(?:\\s+\\d{4})?$"),
            Regex("\\s+\\d{4}\\s+重制(?:版)?$"),
            Regex("\\s+重制(?:版)?(?:\\s+\\d{4})?$"),
        )
        patterns.forEach { value = value.replace(it, "") }
        return value.trim()
    }

    private fun normalize(raw: String): String {
        val folded = Normalizer.normalize(raw, Normalizer.Form.NFKD)
            .replace(Regex("\\p{M}+"), "")
            .lowercase(Locale.ROOT)
        return folded.map { if (it.isLetterOrDigit()) it else ' ' }
            .joinToString("")
            .trim()
            .replace(Regex("\\s+"), " ")
    }

    private fun similarity(left: String, right: String): Double {
        if (left == right) return 1.0
        if (left.isEmpty() || right.isEmpty()) return 0.0
        val denominator = max(left.length, right.length)
        var previous = IntArray(right.length + 1) { it }
        left.forEachIndexed { i, a ->
            val current = IntArray(right.length + 1)
            current[0] = i + 1
            right.forEachIndexed { j, b ->
                val cost = if (a == b) 0 else 1
                current[j + 1] = min(min(current[j] + 1, previous[j + 1] + 1), previous[j] + cost)
            }
            previous = current
        }
        return 1.0 - previous[right.length].toDouble() / denominator.toDouble()
    }
}
