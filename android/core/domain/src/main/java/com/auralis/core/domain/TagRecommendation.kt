// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
package com.auralis.core.domain

import java.text.Normalizer
import java.util.Locale
import kotlin.math.ln

data class TagRecommendationQuery(
    val includeTags: List<String> = emptyList(),
    val preferTags: List<String> = emptyList(),
    val excludeTags: List<String> = emptyList(),
    val numericRanges: Map<String, IntRange> = emptyMap(),
    val excludedTrackIds: Set<String> = emptySet(),
    val minimumConfidence: Double = 0.35,
    val maxPerArtist: Int = 2,
    val maxPerAlbum: Int = 2,
    val limit: Int = 20,
) {
    val hasIntent: Boolean get() = includeTags.isNotEmpty() || preferTags.isNotEmpty() || numericRanges.isNotEmpty()

    fun validated(): TagRecommendationQuery {
        fun resolve(values: List<String>): List<String> = values.map { raw ->
            val value = raw.trim()
            RecommendationIndexTaxonomy.definition(value)?.id ?: run {
                val matches = RecommendationIndexTaxonomy.definitions.filter { it.displayName.equals(value, true) }
                require(matches.size == 1) { "标签未知或有歧义：$raw；请使用 taxonomy 工具返回的稳定 TagID" }
                matches.single().id
            }
        }.distinct().sorted()
        require(minimumConfidence.isFinite() && minimumConfidence in 0.0..1.0) { "无效的 minimumConfidence" }
        numericRanges.forEach { (dimension, range) ->
            val upper = RecommendationIndex.numericUpperBounds[dimension]
            require(upper != null && !range.isEmpty() && range.first >= 1 && range.last <= upper) { "无效的数值范围：$dimension" }
        }
        val result = copy(includeTags = resolve(includeTags), preferTags = resolve(preferTags), excludeTags = resolve(excludeTags),
            maxPerArtist = maxPerArtist.coerceIn(1, 10), maxPerAlbum = maxPerAlbum.coerceIn(1, 10), limit = limit.coerceIn(1, 100))
        require(result.hasIntent) { "请提供正向标签或数值范围；不会从整库随机补足" }
        return result
    }
}

data class TagRecommendationCandidate(val track: Track, val tags: Map<String, Double>, val numericFeatures: Map<String, Int> = emptyMap())
data class TagRecommendationPick(val track: Track, val score: Double, val matchedTags: List<String>)

/** Same content scoring and diversity contract as Apple's TagRecommendationRanker. */
object TagRecommendationRanker {
    fun applyDiversityLimits(tracks: List<Track>, query: TagRecommendationQuery): List<Track> {
        val artists = mutableMapOf<String, Int>()
        val albums = mutableMapOf<String, Int>()
        val recordings = mutableSetOf<String>()
        return tracks.filter { track ->
            val artist = artist(track)
            val album = album(track)
            if ((artists[artist] ?: 0) >= query.maxPerArtist || (album?.let { albums[it] } ?: 0) >= query.maxPerAlbum
                || !recordings.add(TrackQuality.recordingKey(track))) false else {
                artists[artist] = (artists[artist] ?: 0) + 1
                if (album != null) albums[album] = (albums[album] ?: 0) + 1
                true
            }
        }.take(query.limit)
    }

    fun satisfiesHardConstraints(candidate: TagRecommendationCandidate, query: TagRecommendationQuery): Boolean {
        val reliable = candidate.tags.filterValues { it.isFinite() && it >= query.minimumConfidence }.keys
        return reliable.containsAll(query.includeTags) && query.excludeTags.none { it in candidate.tags }
            && candidate.track.globalId.serialized !in query.excludedTrackIds
            && query.numericRanges.all { (dimension, range) -> candidate.numericFeatures[dimension]?.let { it in range } == true }
    }

    fun recommend(candidates: List<TagRecommendationCandidate>, raw: TagRecommendationQuery, existingTracks: List<Track> = emptyList()): List<TagRecommendationPick> {
        val query = raw.validated()
        val prefer = query.preferTags.toSet()
        val preferences = prefer.groupBy { it.substringBefore('.') }
        val existingIds = existingTracks.map { it.globalId.serialized }.toSet()
        val recordings = existingTracks.map(TrackQuality::recordingKey).toSet()
        val eligible = candidates.filter { candidate ->
            val reliable = candidate.tags.filterValues { it.isFinite() && it >= query.minimumConfidence }.keys
            candidate.track.globalId.serialized !in existingIds && TrackQuality.recordingKey(candidate.track) !in recordings
                && satisfiesHardConstraints(candidate, query)
                && (prefer.isEmpty() || query.includeTags.isNotEmpty() || query.numericRanges.isNotEmpty() || prefer.any { it in reliable })
        }
        val frequencies = eligible.flatMap { it.tags.filterValues { confidence -> confidence.isFinite() && confidence >= query.minimumConfidence }.keys }.groupingBy { it }.eachCount()
        val weights = prefer.associateWith { 1.0 + ln((eligible.size + 1.0) / ((frequencies[it] ?: 0) + 1.0)) }
        val byId = eligible.associateBy { it.track.globalId.serialized }
        val unique = eligible.map { it.track }.sortedWith(compareByDescending<Track> { TrackQuality.score(it) }.thenBy { it.globalId.serialized })
            .distinctBy(TrackQuality::recordingKey)
        data class Scored(val pick: TagRecommendationPick, val tags: Set<String>, var redundancy: Double = 0.0)
        val pool = unique.map { track ->
            val candidate = byId.getValue(track.globalId.serialized)
            val matched = candidate.tags.filterValues { it.isFinite() && it >= query.minimumConfidence }.keys
            val relevance = if (prefer.isEmpty()) 1.0 else preferences.values.sumOf { tags ->
                val denominator = tags.maxOf { weights.getValue(it) }
                tags.maxOf { if (it in matched) candidate.tags.getValue(it).coerceAtMost(1.0) * weights.getValue(it) / denominator else 0.0 }
            } / preferences.size
            val confidence = matched.maxOfOrNull { candidate.tags.getValue(it).coerceAtMost(1.0) } ?: 0.0
            Scored(TagRecommendationPick(track, 0.9 * relevance + 0.1 * confidence, matched.intersect(prefer + query.includeTags).sorted()), matched)
        }.toMutableList()
        val artists = existingTracks.groupingBy(::artist).eachCount().toMutableMap()
        val albums = existingTracks.mapNotNull(::album).groupingBy { it }.eachCount().toMutableMap()
        val selected = mutableListOf<TagRecommendationPick>()
        while (selected.size < query.limit && pool.isNotEmpty()) {
            var best = -1
            var bestScore = Double.NEGATIVE_INFINITY
            pool.forEachIndexed { index, item ->
                val artistCount = artists[artist(item.pick.track)] ?: 0
                val albumCount = album(item.pick.track)?.let { albums[it] } ?: 0
                if (artistCount < query.maxPerArtist && albumCount < query.maxPerAlbum) {
                    val score = item.pick.score - 0.18 * artistCount - 0.10 * albumCount - 0.08 * item.redundancy
                    if (score > bestScore || (score == bestScore && best >= 0 && item.pick.track.globalId.serialized < pool[best].pick.track.globalId.serialized)) {
                        best = index; bestScore = score
                    }
                }
            }
            if (best < 0) break
            val item = pool.removeAt(best)
            selected += item.pick
            val artist = artist(item.pick.track)
            artists[artist] = (artists[artist] ?: 0) + 1
            album(item.pick.track)?.let { albums[it] = (albums[it] ?: 0) + 1 }
            pool.forEach { other ->
                val overlap = other.tags.intersect(item.tags).size.toDouble() / other.tags.union(item.tags).size.coerceAtLeast(1)
                other.redundancy = maxOf(other.redundancy, overlap)
            }
        }
        return selected
    }

    private fun normalize(value: String): String = Normalizer.normalize(value, Normalizer.Form.NFKD)
        .replace(Regex("\\p{M}+"), "").trim().replace(Regex("\\s+"), " ").lowercase(Locale.ROOT)
    private fun artist(track: Track): String = normalize(track.artistName).ifEmpty { "${track.serverId.value}:${track.artistId.value}" }
    private fun album(track: Track): String? = normalize(track.albumTitle).takeIf { it.isNotEmpty() }?.let { "${artist(track)}|$it" }
}
