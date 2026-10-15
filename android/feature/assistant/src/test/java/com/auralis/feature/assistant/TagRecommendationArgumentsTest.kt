// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
package com.auralis.feature.assistant

import com.google.common.truth.Truth.assertThat
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertThrows
import org.junit.Test

class TagRecommendationArgumentsTest {
    @Test fun parsesAlternativeGroupsAndCanonicalMinimumMatchCounts() {
        val args = Json.parseToJsonElement("""{"anyTagGroups":[["自习","钢琴"],["深夜","木吉他"]],"preferTags":["自习","学习","钢琴"],"minimumPreferredMatches":2}""").jsonObject
        val query = TagRecommendationArguments.query(args, 10).validated()
        assertThat(query.anyTagGroups).containsExactly(listOf("instrument.piano", "scene.study"), listOf("instrument.acoustic_guitar", "scene.late_night"))
        assertThat(query.preferTags).hasSize(2)
        assertThat(query.minimumPreferredMatches).isEqualTo(2)
        for (bad in listOf("\"bad\"", "[[]]", "[[2]]", "[[\"\"]]")) {
            assertThrows(IllegalArgumentException::class.java) {
                TagRecommendationArguments.query(Json.parseToJsonElement("""{"anyTagGroups":$bad}""").jsonObject, 10)
            }
        }
        for (bad in listOf("1.5", "1e100", "\"2\"", "-1", "4")) {
            assertThrows(IllegalArgumentException::class.java) {
                TagRecommendationArguments.query(Json.parseToJsonElement("""{"preferTags":["scene.study"],"minimumPreferredMatches":$bad}""").jsonObject, 10).validated()
            }
        }
    }
    @Test fun parsesHardAndSoftIntentAndRanges() {
        val args = Json.parseToJsonElement("""{"includeTags":["instrument.piano"],"preferTags":["scene.late_night"],"excludeTags":["mood.sad"],"numericRanges":{"energy":[1,4]},"excludeTrackIDs":["server:1"]}""").jsonObject
        val query = TagRecommendationArguments.query(args, 10).validated()
        assertThat(query.includeTags).containsExactly("instrument.piano")
        assertThat(query.numericRanges["energy"]).isEqualTo(1..4)
        assertThat(query.excludedTrackIds).containsExactly("server:1")
    }

    @Test fun invalidRangesCannotBecomeMissingConstraints() {
        for (range in listOf("[5,1]", "[0,4]", "[1,11]", "[1.5,4]", "[]", "null")) {
            val args = Json.parseToJsonElement("""{"numericRanges":{"energy":$range}}""").jsonObject
            assertThrows(IllegalArgumentException::class.java) { TagRecommendationArguments.query(args, 10) }
        }
        assertThrows(IllegalArgumentException::class.java) {
            TagRecommendationArguments.query(Json.parseToJsonElement("""{"includeTags":"bad"}""").jsonObject, 10)
        }
    }

    @Test fun collisionSchemaRetainsCandidateContractAndAddsTagProperties() {
        val schema = TagRecommendationArguments.collisionSchema("""{"type":"object","properties":{"candidates":{"type":"array"}},"required":["candidates"]}""")
        val properties = Json.parseToJsonElement(schema).jsonObject.getValue("properties").jsonObject
        assertThat(properties.keys).containsAtLeast("candidates", "includeTags", "preferTags", "excludeTags", "numericRanges", "anyTagGroups", "minimumPreferredMatches")
        assertThat(properties.keys).doesNotContain("limit")
    }
}
