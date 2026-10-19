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

private class ClassifierProvider(
    override val capabilities: ModelCapabilities = ModelCapabilities(supportsStreaming = false),
    val handler: suspend (AiCompletionRequest) -> AiCompletionResponse,
) : AiProvider {
    override suspend fun testConnection(): AiConnectionResult = error("No probes expected")
    override suspend fun complete(request: AiCompletionRequest) = handler(request)
    override fun stream(request: AiCompletionRequest): Flow<AiStreamEvent> = emptyFlow()
}

class TagClassificationRunnerTest : RoomDbTest() {
    @Test fun smallContextConsidersEveryLabelAndCommitsAllPartsTogether() = runBlocking<Unit> {
        val db = openDatabase()
        try {
            db.trackDao().upsertAll((0..1).map { track("$it").entity() })
            val store = RecommendationIndexStore(db)
            val seen = mutableSetOf<String>()
            var calls = 0
            val provider = ClassifierProvider(ModelCapabilities(maxContextTokens = 4096, supportsStreaming = false)) { request ->
                calls++
                assertThat(ContextBudget.estimateMessages(request.messages) + request.maxTokens + 256).isAtMost(4096)
                assertThat(store.status(server).indexedTracks).isEqualTo(0)
                val catalog = request.messages.first().content
                RecommendationIndexTaxonomy.definitions.filter { catalog.contains("${it.id}=") }.forEach { seen += it.id }
                val ids = Json.parseToJsonElement(request.messages.last().content).jsonObject.getValue("items").jsonArray
                AiCompletionResponse(request.model, buildJsonObject { putJsonArray("items") { ids.forEach { item -> addJsonObject {
                    put("id", item.jsonObject.getValue("id"))
                    putJsonArray("tags") { listOf("scene.study", "instrument.piano").filter { catalog.contains("$it=") }.forEach { add(it) } }
                } } } }.toString())
            }
            TagClassificationRunner(store, provider, "small-context").run(server)
            assertThat(calls).isGreaterThan(1)
            assertThat(seen).containsExactlyElementsIn(RecommendationIndexTaxonomy.definitions.map { it.id })
            assertThat(store.status(server).indexedTracks).isEqualTo(2)
            assertThat(store.recommendByTags(server, TagRecommendationQuery(includeTags = listOf("scene.study", "instrument.piano")))).hasSize(2)
        } finally { db.close() }
    }
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
            TagClassificationRunner(store, ClassifierProvider(handler = ::response), "text-only").run(server)
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
            assertThat(calls).isEqualTo(4) // The actual three-track failure shrinks to one, and stays small.
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
            TagClassificationRunner(store, ClassifierProvider(handler = ::response), "text-only").run(server)
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

    @Test fun thousandTrackLibraryUsesBoundedBatchesWithoutRepeatingTracks() = runBlocking<Unit> {
        val db = openDatabase()
        try {
            db.trackDao().upsertAll((0..1000).map { track("$it").entity() })
            val store = RecommendationIndexStore(db)
            val ids = mutableListOf<String>()
            val sizes = mutableListOf<Int>()
            val provider = ClassifierProvider { request ->
                val items = Json.parseToJsonElement(request.messages.last().content).jsonObject.getValue("items").jsonArray
                sizes += items.size
                ids += items.map { it.jsonObject.getValue("id").jsonPrimitive.content }
                response(request)
            }
            TagClassificationRunner(store, provider, "text-only").run(server)
            assertThat(store.status(server).indexedTracks).isEqualTo(1001)
            assertThat(ids).hasSize(1001)
            assertThat(ids.distinct()).hasSize(1001)
            assertThat(sizes).containsExactlyElementsIn(List(125) { 8 } + 1).inOrder()
        } finally { db.close() }
    }

    @Test fun allConfiguredProtocolsClassifyOverStreamingAndOrdinaryHttp() = runBlocking<Unit> {
        for (path in listOf("/v1/chat/completions", "/v1/responses", "/v1/messages")) {
            for (streaming in listOf(false, true)) {
                val db = openDatabase()
                val upstream = MockWebServer()
                try {
                    db.trackDao().upsertAll(listOf(track("0").entity()))
                    val content = """{"items":[{"id":"server:0","tags":["scene.study","scene.study","instrument.piano"],"features":{"energy":4},"confidence":0.9}]}"""
                    val quoted = JsonPrimitive(content).toString()
                    val ordinary = when (path) {
                        "/v1/responses" -> """{"model":"text-only","status":"completed","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":$quoted}]}]}"""
                        "/v1/messages" -> """{"model":"text-only","content":[{"type":"text","text":$quoted}],"stop_reason":"end_turn"}"""
                        else -> """{"model":"text-only","choices":[{"message":{"role":"assistant","content":$quoted},"finish_reason":"stop"}]}"""
                    }
                    val events = when (path) {
                        "/v1/responses" -> "data: {\"type\":\"response.output_text.delta\",\"delta\":$quoted}\n\n" +
                            "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[]}}\n\n"
                        "/v1/messages" -> "data: {\"type\":\"message_start\",\"message\":{\"model\":\"text-only\"}}\n\n" +
                            "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":$quoted}}\n\n" +
                            "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"}}\n\n" +
                            "data: {\"type\":\"message_stop\"}\n\n"
                        else -> "data: {\"model\":\"text-only\",\"choices\":[{\"delta\":{\"content\":$quoted}}]}\n\n" +
                            "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n" + "data: [DONE]\n\n"
                    }
                    upstream.enqueue(MockResponse().setHeader("Content-Type", if (streaming) "text/event-stream" else "application/json")
                        .setBody(if (streaming) events else ordinary))
                    upstream.start()
                    val provider = AiProviderFactory.create(AiProviderConfiguration(id = "test", name = "test",
                        baseUrl = upstream.url("/").toString(), apiPath = path, model = "text-only", usesStreaming = streaming), apiKeyProvider = { null })
                    val store = RecommendationIndexStore(db)
                    withTimeout(20_000) {
                        TagClassificationRunner(store, provider, "text-only", requestTimeoutMillis = 3000,
                            sleep = { throw AssertionError("Unexpected retry: $path streaming=$streaming") }).run(server)
                    }
                    assertThat(store.status(server).indexedTracks).isEqualTo(1)
                    assertThat(store.recommendByTags(server, TagRecommendationQuery(includeTags = listOf("scene.study", "instrument.piano"),
                        numericRanges = mapOf("energy" to 4..4)))).hasSize(1)
                    val sent = Json.parseToJsonElement(upstream.takeRequest().body.readUtf8()).jsonObject
                    assertThat(sent.keys).doesNotContain("tools")
                    assertThat(sent["stream"]?.jsonPrimitive?.boolean ?: false).isEqualTo(streaming)
                } finally { upstream.shutdown(); db.close() }
            }
        }
    }

    @Test fun timeoutAfterFirstSavedBatchRetriesOnlyPendingTracks() = runBlocking<Unit> {
        val db = openDatabase()
        try {
            db.trackDao().upsertAll((0..9).map { track("$it").entity() })
            val store = RecommendationIndexStore(db)
            val sizes = mutableListOf<Int>()
            val waits = mutableListOf<Long>()
            var calls = 0
            val provider = ClassifierProvider { request ->
                sizes += Json.parseToJsonElement(request.messages.last().content).jsonObject.getValue("items").jsonArray.size
                if (++calls == 2) awaitCancellation()
                response(request)
            }
            TagClassificationRunner(store, provider, "text-only", requestTimeoutMillis = 200,
                sleep = { waits += it }).run(server)
            assertThat(store.status(server).indexedTracks).isEqualTo(10)
            assertThat(sizes).containsExactly(8, 2, 2).inOrder()
            assertThat(waits).containsExactly(15_000L)
        } finally { db.close() }
    }

    @Test fun transientFailuresBackOffButAuthenticationStopsImmediately() = runBlocking<Unit> {
        val db = openDatabase()
        try {
            db.trackDao().upsertAll(listOf(track("0").entity()))
            val store = RecommendationIndexStore(db)
            val waits = mutableListOf<Long>()
            var calls = 0
            val provider = ClassifierProvider { request ->
                if (++calls <= 7) throw AiProviderException(AiProviderFailureKind.UpstreamRouting, "503", httpStatus = 503, retryable = true)
                response(request)
            }
            TagClassificationRunner(store, provider, "text-only", sleep = { waits += it }).run(server)
            assertThat(waits).containsExactly(15_000L, 30_000L, 60_000L, 120_000L, 240_000L, 300_000L, 300_000L).inOrder()
            db.trackDao().upsertAll(listOf(track("1").entity()))
            calls = 0
            val denied = ClassifierProvider { ++calls; throw AiProviderException(AiProviderFailureKind.Authentication, "401", httpStatus = 401) }
            val error = runCatching { TagClassificationRunner(store, denied, "text-only", sleep = { error("Must not retry 401") }).run(server) }.exceptionOrNull()
            assertThat(error).isInstanceOf(AiProviderException::class.java)
            assertThat(calls).isEqualTo(1)
            assertThat(store.status(server).indexedTracks).isEqualTo(1)
        } finally { db.close() }
    }

    @Test fun cancellationDuringBackoffKeepsSavedBatchAndStopsRequests() = runBlocking<Unit> {
        val db = openDatabase()
        try {
            db.trackDao().upsertAll((0..9).map { track("$it").entity() })
            val store = RecommendationIndexStore(db)
            val waiting = CompletableDeferred<Unit>()
            var calls = 0
            val provider = ClassifierProvider { request ->
                if (++calls == 2) throw java.io.IOException("offline")
                response(request)
            }
            val task = launch { TagClassificationRunner(store, provider, "text-only", sleep = {
                waiting.complete(Unit); awaitCancellation()
            }).run(server) }
            withTimeout(10_000) { waiting.await() }
            task.cancelAndJoin()
            assertThat(calls).isEqualTo(2)
            assertThat(store.status(server).indexedTracks).isEqualTo(8)
        } finally { db.close() }
    }

    @Test fun cancellingDuringLaterTaxonomyGroupCannotCommitEarlierLabels() = runBlocking<Unit> {
        val db = openDatabase()
        try {
            db.trackDao().upsertAll(listOf(track("0").entity()))
            val store = RecommendationIndexStore(db)
            val waiting = CompletableDeferred<Unit>()
            var calls = 0
            val provider = ClassifierProvider(ModelCapabilities(maxContextTokens = 4096, supportsStreaming = false)) { request ->
                if (++calls == 2) { waiting.complete(Unit); awaitCancellation() }
                response(request)
            }
            val task = launch { TagClassificationRunner(store, provider, "text-only").run(server) }
            withTimeout(10_000) { waiting.await() }
            task.cancelAndJoin()
            assertThat(store.status(server).indexedTracks).isEqualTo(0)
        } finally { db.close() }
    }

    @Test fun emptyStreamRecoversWithoutSavingReasoningAndKeepsReasoningConfiguration() = runBlocking<Unit> {
        val db = openDatabase()
        try {
            db.trackDao().upsertAll(listOf(track("0").entity()))
            val store = RecommendationIndexStore(db)
            val configured = AiReasoningConfiguration(effort = AiReasoningEffort.High)
            var completions = 0
            val provider = object : AiProvider {
                override suspend fun testConnection(): AiConnectionResult = error("No probes")
                override fun stream(request: AiCompletionRequest) = kotlinx.coroutines.flow.flow {
                    assertThat(request.reasoning).isEqualTo(configured)
                    emit(AiStreamEvent.ReasoningDelta("private reasoning must not become tags"))
                    emit(AiStreamEvent.UnknownDelta("""{"items":[{"id":"server:0","tags":["scene.late_night"]}]}"""))
                    emit(AiStreamEvent.Completed)
                }
                override suspend fun complete(request: AiCompletionRequest): AiCompletionResponse {
                    completions++
                    assertThat(request.reasoning).isEqualTo(configured)
                    return response(request)
                }
            }
            TagClassificationRunner(store, provider, "text-only", reasoning = configured).run(server)
            assertThat(completions).isEqualTo(1)
            assertThat(store.recommendByTags(server, TagRecommendationQuery(includeTags = listOf("scene.study", "instrument.piano")))).hasSize(1)
            assertThat(store.recommendByTags(server, TagRecommendationQuery(includeTags = listOf("scene.late_night")))).isEmpty()
        } finally { db.close() }
    }

    @Test fun completeJsonFromInterruptedStreamIsNotCommitted() = runBlocking<Unit> {
        val db = openDatabase()
        try {
            db.trackDao().upsertAll(listOf(track("0").entity()))
            val store = RecommendationIndexStore(db)
            val provider = object : AiProvider {
                override suspend fun testConnection(): AiConnectionResult = error("No probes")
                override suspend fun complete(request: AiCompletionRequest): AiCompletionResponse = error("Must not recover interrupted streams")
                override fun stream(request: AiCompletionRequest) = kotlinx.coroutines.flow.flow {
                    emit(AiStreamEvent.AnswerDelta(response(request).content))
                    emit(AiStreamEvent.Terminated(AiStreamTermination(AiStreamTerminationKind.Interrupted, "EOF")))
                }
            }
            val error = runCatching { TagClassificationRunner(store, provider, "text-only", sleep = {
                throw CancellationException("Paused during retry")
            }).run(server) }.exceptionOrNull()
            assertThat(error).isInstanceOf(CancellationException::class.java)
            assertThat(store.status(server).indexedTracks).isEqualTo(0)
        } finally { db.close() }
    }

    @Test fun repeatedEmptyBodiesBackOffAndRecoverWithoutMarkingTracksComplete() = runBlocking<Unit> {
        val db = openDatabase()
        try {
            db.trackDao().upsertAll(listOf(track("0").entity()))
            val store = RecommendationIndexStore(db)
            val waits = mutableListOf<Long>()
            var calls = 0
            val provider = ClassifierProvider { request ->
                assertThat(store.status(server).indexedTracks).isEqualTo(0)
                if (++calls <= 2) AiCompletionResponse(request.model, "", reasoning = "not labels") else response(request)
            }
            TagClassificationRunner(store, provider, "text-only", sleep = { waits += it }).run(server)
            assertThat(calls).isEqualTo(3)
            assertThat(waits).containsExactly(15_000L)
            assertThat(store.status(server).indexedTracks).isEqualTo(1)
        } finally { db.close() }
    }

    @Test fun bufferedFinalResponseRecoversThroughOrdinaryHttp() = runBlocking<Unit> {
        val db = openDatabase()
        val upstream = MockWebServer()
        try {
            db.trackDao().upsertAll(listOf(track("0").entity()))
            val quoted = JsonPrimitive("""{"items":[{"id":"server:0","tags":["scene.study","instrument.piano"]}]}""").toString()
            val body = """{"model":"text-only","status":"completed","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":$quoted}]}]}"""
            upstream.enqueue(MockResponse().setHeader("Content-Type", "text/event-stream")
                .setBody("data: {\"type\":\"response.completed\",\"response\":$body}\n\n"))
            upstream.enqueue(MockResponse().setHeader("Content-Type", "application/json").setBody(body))
            upstream.start()
            val provider = AiProviderFactory.create(AiProviderConfiguration(id = "test", name = "test",
                baseUrl = upstream.url("/").toString(), apiPath = "/v1/responses", model = "text-only"), apiKeyProvider = { null })
            val store = RecommendationIndexStore(db)
            withTimeout(20_000) {
                TagClassificationRunner(store, provider, "text-only", requestTimeoutMillis = 3000,
                    sleep = { throw AssertionError("Expected ordinary recovery before backoff") }).run(server)
            }
            assertThat(upstream.requestCount).isEqualTo(2)
            assertThat(store.status(server).indexedTracks).isEqualTo(1)
            assertThat(store.recommendByTags(server, TagRecommendationQuery(includeTags = listOf("scene.study", "instrument.piano")))).hasSize(1)
        } finally { upstream.shutdown(); db.close() }
    }
}
