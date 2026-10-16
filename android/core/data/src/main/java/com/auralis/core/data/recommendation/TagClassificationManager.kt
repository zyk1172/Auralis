// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
package com.auralis.core.data.recommendation

import android.content.Intent
import androidx.core.content.ContextCompat
import com.auralis.core.ai.AiProviderConfiguration
import com.auralis.core.ai.AiProviderFactory
import com.auralis.core.data.graph.AuralisGraph
import com.auralis.core.data.prefs.AiConnectionSettings
import com.auralis.core.domain.RecommendationIndexStatus
import com.auralis.core.domain.RecommendationIndexUiState
import com.auralis.core.domain.ServerId
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** One process-owned job. Closing a page, Activity recreation and chat cancellation cannot stop it. */
class TagClassificationManager(private val graph: AuralisGraph) {
    private val mutableState = MutableStateFlow(RecommendationIndexUiState())
    val state = mutableState.asStateFlow()
    private var job: Job? = null

    @Synchronized fun start() {
        if (mutableState.value.isRunning) return
        mutableState.update { it.copy(isRunning = true, isPaused = false, error = null) }
        try {
            ContextCompat.startForegroundService(graph.appContext, Intent(graph.appContext, TagClassificationService::class.java))
        } catch (error: Exception) {
            mutableState.update { it.copy(isRunning = false, error = error.message) }
        }
    }

    @Synchronized internal fun runFromService() {
        if (job != null || !mutableState.value.isRunning) return
        job = graph.appScope.launch(start = CoroutineStart.LAZY) {
            var server: ServerId? = null
            try {
                val target = graph.preferences.activeServerIdValue()?.takeIf { it.isNotBlank() }?.let(::ServerId)
                    ?: throw IllegalArgumentException("请先选择并同步音乐库")
                server = target
                authorize(target)
                val settings = graph.preferences.aiConnectionValue()
                require(settings.isComplete) { "请先在设置中配置大模型" }
                val key = graph.vault.retrieve(AiConnectionSettings.API_KEY_REFERENCE)
                val provider = AiProviderFactory.create(AiProviderConfiguration(
                    id = "tag-classification", name = "标签分类", baseUrl = settings.baseUrl,
                    apiPath = settings.apiPath, model = settings.model, credentialId = AiConnectionSettings.API_KEY_REFERENCE,
                    maxTokens = settings.maxOutputTokens, maxContextTokens = settings.maxContextTokens,
                    usesStreaming = false, supportsToolCalling = false,
                    assumesImplicitStreamTermination = settings.assumesImplicitStreamTermination,
                ), apiKeyProvider = { key })
                TagClassificationRunner(graph.recommendationIndex, provider, settings.model,
                    maxOutputTokens = settings.maxOutputTokens).run(target, authorize = { authorize(target) }) { progress ->
                    mutableState.update { it.copy(progress = progress, status = RecommendationIndexStatus(
                        progress.totalTracks, progress.indexedTracks, progress.pendingTracks)) }
                }
                mutableState.update { it.copy(lastCompletedAtMillis = System.currentTimeMillis()) }
            } catch (error: CancellationException) {
                mutableState.update { it.copy(isPaused = true) }
            } catch (error: Exception) {
                mutableState.update { it.copy(error = error.message ?: "分类失败，请重试") }
            } finally {
                withContext(NonCancellable) {
                    val status = server?.let { runCatching { graph.recommendationIndex.status(it) }.getOrNull() }
                    synchronized(this@TagClassificationManager) {
                        mutableState.update { it.copy(isRunning = false, status = status ?: it.status) }
                        job = null
                    }
                }
            }
        }
        job?.start()
    }

    private suspend fun authorize(server: ServerId) {
        require(graph.preferences.activeServerIdValue() == server.value) { "音乐库已切换，分类已停止" }
        require(graph.preferences.aiEnabledValue()) { "请先启用 AI 功能" }
        require(graph.preferences.aiPrivacyPermissionsValue().allowsMetadata) { "请在隐私设置中允许歌曲元数据" }
        require(graph.preferences.classificationConsentValue()) { "请在设置中的标签分类确认元数据外发授权" }
    }

    @Synchronized fun pause() {
        mutableState.update { it.copy(isPaused = true) }
        if (job == null) mutableState.update { it.copy(isRunning = false) }
        job?.cancel()
    }

    internal fun serviceStartFailed(error: Exception) {
        mutableState.update { it.copy(isRunning = false, error = error.message ?: "系统暂不允许后台分类，请回到应用重试") }
    }

    fun refresh() {
        graph.appScope.launch {
            if (mutableState.value.isRunning) return@launch
            val server = graph.preferences.activeServerIdValue()?.takeIf { it.isNotBlank() }?.let(::ServerId)
            val status = server?.let { runCatching { graph.recommendationIndex.status(it) }.getOrNull() }
            mutableState.update { if (it.isRunning) it else it.copy(status = status) }
        }
    }
}
