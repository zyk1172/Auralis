// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
package com.auralis.core.domain

import java.text.Normalizer
import java.util.Locale
import kotlin.math.ln

data class TagRecommendationQuery(
    val includeTags: List<String> = emptyList(),
    val preferTags: List<String> = emptyList(),
    val excludeTags: List<String> = emptyList(),
    val anyTagGroups: List<List<String>> = emptyList(),
    val minimumPreferredMatches: Int = 0,
    val numericRanges: Map<String, IntRange> = emptyMap(),
    val excludedTrackIds: Set<String> = emptySet(),
    val minimumConfidence: Double = 0.35,
    val maxPerArtist: Int = 2,
    val maxPerAlbum: Int = 2,
    val limit: Int = 20,
) {
    val hasIntent: Boolean get() = includeTags.isNotEmpty() || preferTags.isNotEmpty() || anyTagGroups.isNotEmpty() || numericRanges.isNotEmpty()
    val hasHardTagConditions: Boolean get() = includeTags.isNotEmpty() || anyTagGroups.isNotEmpty() || minimumPreferredMatches > 0 || excludeTags.isNotEmpty() || numericRanges.isNotEmpty()

    fun validated(): TagRecommendationQuery {
        fun resolve(values: List<String>): List<String> = values.map { raw ->
            requireNotNull(RecommendationIndexTaxonomy.resolve(raw)) { "标签未知或有歧义：$raw；请使用 taxonomy 工具返回的稳定 TagID" }.id
        }.distinct().sorted()
        require(minimumConfidence.isFinite() && minimumConfidence in 0.0..1.0) { "无效的 minimumConfidence" }
        numericRanges.forEach { (dimension, range) ->
            val upper = RecommendationIndex.numericUpperBounds[dimension]
            require(upper != null && !range.isEmpty() && range.first >= 1 && range.last <= upper) { "无效的数值范围：$dimension" }
        }
        require(anyTagGroups.size <= 20 && anyTagGroups.all { it.isNotEmpty() && it.size <= 20 }) { "anyTagGroups 最多20组，每组1..20个标签" }
        val preferred = resolve(preferTags)
        require(minimumPreferredMatches in 0..preferred.size) { "无效的 minimumPreferredMatches" }
        val result = copy(includeTags = resolve(includeTags), preferTags = preferred, excludeTags = resolve(excludeTags),
            anyTagGroups = anyTagGroups.map(::resolve).distinct().sortedBy { it.joinToString("\u0000") },
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
            && (query.anyTagGroups.isEmpty() || query.anyTagGroups.any { reliable.containsAll(it) })
            && reliable.intersect(query.preferTags.toSet()).size >= query.minimumPreferredMatches
            && candidate.track.globalId.serialized !in query.excludedTrackIds
            && query.numericRanges.all { (dimension, range) -> candidate.numericFeatures[dimension]?.let { it in range } == true }
    }

    fun recommend(candidates: List<TagRecommendationCandidate>, raw: TagRecommendationQuery, existingTracks: List<Track> = emptyList()): List<TagRecommendationPick> {
        val query = raw.validated()
        val prefer = query.preferTags.toSet()
        val groupTags = query.anyTagGroups.flatten().toSet()
        val scoringTags = prefer.ifEmpty { groupTags }
        val preferences = scoringTags.sorted().groupBy { it.substringBefore('.') }.toSortedMap()
        val existingIds = existingTracks.map { it.globalId.serialized }.toSet()
        val recordings = existingTracks.map(TrackQuality::recordingKey).toSet()
        val eligible = candidates.filter { candidate ->
            val reliable = candidate.tags.filterValues { it.isFinite() && it >= query.minimumConfidence }.keys
            candidate.track.globalId.serialized !in existingIds && TrackQuality.recordingKey(candidate.track) !in recordings
                && satisfiesHardConstraints(candidate, query)
                && (prefer.isEmpty() || query.includeTags.isNotEmpty() || groupTags.isNotEmpty() || query.numericRanges.isNotEmpty() || prefer.any { it in reliable })
        }
        val frequencies = eligible.flatMap { it.tags.filterValues { confidence -> confidence.isFinite() && confidence >= query.minimumConfidence }.keys }.groupingBy { it }.eachCount()
        val weights = scoringTags.sorted().associateWith { 1.0 + ln((eligible.size + 1.0) / ((frequencies[it] ?: 0) + 1.0)) }
        val byId = eligible.associateBy { it.track.globalId.serialized }
        val unique = eligible.map { it.track }.sortedWith(compareByDescending<Track> { TrackQuality.score(it) }.thenBy { it.globalId.serialized })
            .distinctBy(TrackQuality::recordingKey)
        data class Scored(val pick: TagRecommendationPick, val tags: Set<String>, val artist: String, val album: String?, val id: String, var redundancy: Double = 0.0)
        val pool = unique.map { track ->
            val candidate = byId.getValue(track.globalId.serialized)
            val matched = candidate.tags.filterValues { it.isFinite() && it >= query.minimumConfidence }.keys
            val relevance = if (scoringTags.isEmpty()) 1.0 else {
                val balanced = preferences.values.sumOf { tags ->
                    val denominator = tags.maxOf { weights.getValue(it) }
                    tags.maxOf { if (it in matched) candidate.tags.getValue(it).coerceAtMost(1.0) * weights.getValue(it) / denominator else 0.0 }
                } / preferences.size
                val coverage = scoringTags.sorted().sumOf { if (it in matched) candidate.tags.getValue(it).coerceAtMost(1.0) * weights.getValue(it) else 0.0 } / weights.values.sum()
                0.75 * balanced + 0.25 * coverage
            }
            val confidence = matched.maxOfOrNull { candidate.tags.getValue(it).coerceAtMost(1.0) } ?: 0.0
            Scored(TagRecommendationPick(track, 0.9 * relevance + 0.1 * confidence, matched.intersect(prefer + query.includeTags + groupTags).sorted()),
                matched, artist(track), album(track), track.globalId.serialized)
        }.toMutableList()
        val artists = existingTracks.groupingBy(::artist).eachCount().toMutableMap()
        val albums = existingTracks.mapNotNull(::album).groupingBy { it }.eachCount().toMutableMap()
        val selected = mutableListOf<TagRecommendationPick>()
        while (selected.size < query.limit && pool.isNotEmpty()) {
            var best = -1
            var bestScore = Double.NEGATIVE_INFINITY
            pool.forEachIndexed { index, item ->
                val artistCount = artists[item.artist] ?: 0
                val albumCount = item.album?.let { albums[it] } ?: 0
                if (artistCount < query.maxPerArtist && albumCount < query.maxPerAlbum) {
                    val score = item.pick.score - 0.18 * artistCount - 0.10 * albumCount - 0.08 * item.redundancy
                    if (score > bestScore || (score == bestScore && best >= 0 && item.id < pool[best].id)) {
                        best = index; bestScore = score
                    }
                }
            }
            if (best < 0) break
            val item = pool.removeAt(best)
            selected += item.pick
            val artist = item.artist
            artists[artist] = (artists[artist] ?: 0) + 1
            item.album?.let { albums[it] = (albums[it] ?: 0) + 1 }
            pool.forEach { other ->
                val overlap = other.tags.intersect(item.tags).size.toDouble() / other.tags.union(item.tags).size.coerceAtLeast(1)
                other.redundancy = maxOf(other.redundancy, overlap)
            }
        }
        return selected
    }

    private val marks = Regex("\\p{M}+")
    private val whitespace = Regex("\\s+")
    private fun normalize(value: String): String = Normalizer.normalize(value, Normalizer.Form.NFKD)
        .replace(marks, "").trim().replace(whitespace, " ").lowercase(Locale.ROOT)
    private fun artist(track: Track): String = normalize(track.artistName).ifEmpty { "${track.serverId.value}:${track.artistId.value}" }
    private fun album(track: Track): String? = normalize(track.albumTitle).takeIf { it.isNotEmpty() }?.let { "${artist(track)}|$it" }
}
