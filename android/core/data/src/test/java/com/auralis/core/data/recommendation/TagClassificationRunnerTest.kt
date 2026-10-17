// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
package com.auralis.core.data.recommendation

import com.auralis.core.ai.*
import com.auralis.core.data.RoomDbTest
import com.auralis.core.data.db.DataJson
import com.auralis.core.data.db.TrackEntity
import com.auralis.core.data.repository.RecommendationIndexStore
import com.auralis.core.domain.*
import com.google.common.truth.Truth.assertThat
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.*
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.Test

private class ClassifierProvider(val handler: suspend (AiCompletionRequest) -> AiCompletionResponse) : AiProvider {
    override suspend fun testConnection(): AiConnectionResult = error("No probes expected")
    override suspend fun complete(request: AiCompletionRequest) = handler(request)
    override fun stream(request: AiCompletionRequest): Flow<AiStreamEvent> = emptyFlow()
}

class TagClassificationRunnerTest : RoomDbTest() {
    @Test fun retriesEmptyClassificationsWithoutReplacingExistingLabels() = runBlocking<Unit> {
        val db = openDatabase()
        try {
            val tracks = listOf(track("0"), track("1"))
            db.trackDao().upsertAll(tracks.map { it.entity() })
            val store = RecommendationIndexStore(db)
            store.replaceClassifications(server, listOf(
                RecommendationIndexClassificationInput(tracks[0].globalId, listOf(RecommendationIndexTag("scene", "scene.late_night", 0.9))),
                RecommendationIndexClassificationInput(tracks[1].globalId, emptyList()),
            ))
            assertThat(store.emptyClassificationCount(server)).isEqualTo(1)
            assertThat(store.requeueEmptyClassifications(server)).isEqualTo(1)
            assertThat(store.status(server).indexedTracks).isEqualTo(1)
            TagClassificationRunner(store, ClassifierProvider(::response), "text-only").run(server)
            assertThat(store.emptyClassificationCount(server)).isEqualTo(0)
            assertThat(store.recommendByTags(server, TagRecommendationQuery(includeTags = listOf("scene.late_night"))).map { it.track.id.value }).containsExactly("0")
        } finally { db.close() }
    }
    private val server = ServerId("server")
    private fun track(id: String) = Track(TrackId(id), server, AlbumId(id), ArtistId(id), "Song $id", "Artist $id", "Album $id", 180.0)
    private fun Track.entity() = TrackEntity(globalId.serialized, serverId.value, id.value, title, artistName, albumTitle,
        albumId.value, artistId.value, durationSeconds, year, DataJson.json.encodeToString(this), 1)
    private fun response(request: AiCompletionRequest): AiCompletionResponse {
        val input = Json.parseToJsonElement(request.messages.last().content).jsonObject.getValue("items").jsonArray
        val output = buildJsonObject { putJsonArray("items") { input.forEach { track -> addJsonObject {
            put("id", track.jsonObject.getValue("id")); put("confidence", 0.9)
            putJsonArray("tags") { add("scene.study"); add("scene.focus"); add("instrument.piano") }
        } } } }
        return AiCompletionResponse(request.model, output.toString())
    }

    @Test fun textOnlyModelClassifiesAndCommitsAcrossBatches() = runBlocking<Unit> {
        val db = openDatabase()
        try {
            db.trackDao().upsertAll((0..9).map { track("$it").entity() })
            val store = RecommendationIndexStore(db)
            val requests = mutableListOf<AiCompletionRequest>()
            val provider = ClassifierProvider { requests += it; response(it) }
            TagClassificationRunner(store, provider, "text-only").run(server)
            assertThat(store.status(server).pendingTracks).isEqualTo(0)
            assertThat(requests).hasSize(2)
            assertThat(store.recommendByTags(server, TagRecommendationQuery(includeTags = listOf("scene.study", "instrument.piano"))).size).isEqualTo(10)
            requests.forEach { request ->
                assertThat(request.tools).isNull()
                assertThat(request.messages).hasSize(2)
                assertThat(request.messages.last().content).doesNotContain("playCount")
                assertThat(request.messages.last().content).doesNotContain("isFavorite")
            }
        } finally { db.close() }
    }

    @Test fun partialJsonShrinksAndRetriesWithoutPartialCommits() = runBlocking<Unit> {
        val db = openDatabase()
        try {
            db.trackDao().upsertAll((0..2).map { track("$it").entity() })
            val store = RecommendationIndexStore(db)
            var calls = 0
            val provider = ClassifierProvider { request ->
                calls++
                if (calls == 1) AiCompletionResponse(request.model, "{\"items\":[]}") else response(request)
            }
            TagClassificationRunner(store, provider, "text-only").run(server)
            assertThat(store.status(server).pendingTracks).isEqualTo(0)
            assertThat(calls).isEqualTo(2)
        } finally { db.close() }
    }

    @Test fun pauseKeepsCompletedBatchesAndResumeOnlyProcessesPendingTracks() = runBlocking<Unit> {
        val db = openDatabase()
        try {
            db.trackDao().upsertAll((0..2).map { track("$it").entity() })
            val store = RecommendationIndexStore(db)
            val enteredSecondRequest = CompletableDeferred<Unit>()
            var calls = 0
            val provider = ClassifierProvider { request ->
                if (++calls == 2) { enteredSecondRequest.complete(Unit); awaitCancellation() }
                response(request)
            }
            val running = launch { TagClassificationRunner(store, provider, "text-only", maxOutputTokens = 512).run(server) }
            withTimeout(10_000) { enteredSecondRequest.await() }
            running.cancelAndJoin()
            assertThat(store.status(server).indexedTracks).isEqualTo(1)
            TagClassificationRunner(store, ClassifierProvider(::response), "text-only").run(server)
            assertThat(store.status(server).indexedTracks).isEqualTo(3)
        } finally { db.close() }
    }

    @Test fun changedMetadataAndRevokedPermissionCannotCommitLateResults() = runBlocking<Unit> {
        val db = openDatabase()
        try {
            val original = track("0")
            db.trackDao().upsertAll(listOf(original.entity()))
            val store = RecommendationIndexStore(db)
            val provider = ClassifierProvider { request ->
                db.trackDao().upsertAll(listOf(original.copy(title = "changed").entity()))
                response(request)
            }
            val failure = runCatching { TagClassificationRunner(store, provider, "text-only").run(server) }.exceptionOrNull()
            assertThat(failure).isInstanceOf(IllegalArgumentException::class.java)
            assertThat(store.status(server).indexedTracks).isEqualTo(0)
            var authorized = true
            val revoked = ClassifierProvider { request -> authorized = false; response(request) }
            val revokedFailure = runCatching {
                TagClassificationRunner(store, revoked, "text-only").run(server, authorize = { require(authorized) })
            }.exceptionOrNull()
            assertThat(revokedFailure).isNotNull()
            assertThat(store.status(server).indexedTracks).isEqualTo(0)
        } finally { db.close() }
    }

    @Test fun realHttpCompletionFlowsThroughParserIntoRecommendationIndex() = runBlocking<Unit> {
        val db = openDatabase()
        val upstream = MockWebServer()
        try {
            db.trackDao().upsertAll(listOf(track("0").entity()))
            val content = """{"items":[{"id":"server:0","tags":["scene.study","instrument.piano"],"confidence":0.9}]}"""
            val completion = buildJsonObject { put("model", "text-only"); putJsonArray("choices") { addJsonObject {
                put("finish_reason", "stop"); putJsonObject("message") { put("role", "assistant"); put("content", content) }
            } } }
            upstream.enqueue(MockResponse().setHeader("Content-Type", "application/json").setBody(completion.toString()))
            upstream.start()
            val provider = AiProviderFactory.create(AiProviderConfiguration(id = "test", name = "test", baseUrl = upstream.url("/").toString(),
                apiPath = "/v1/chat/completions", model = "text-only", usesStreaming = false), apiKeyProvider = { null })
            val store = RecommendationIndexStore(db)
            TagClassificationRunner(store, provider, "text-only").run(server)
            assertThat(store.status(server).indexedTracks).isEqualTo(1)
            assertThat(store.recommendByTags(server, TagRecommendationQuery(includeTags = listOf("scene.study", "instrument.piano")))).hasSize(1)
            val request = upstream.takeRequest()
            assertThat(request.path).isEqualTo("/v1/chat/completions")
            assertThat(Json.parseToJsonElement(request.body.readUtf8()).jsonObject.keys).doesNotContain("tools")
        } finally { upstream.shutdown(); db.close() }
    }
}
