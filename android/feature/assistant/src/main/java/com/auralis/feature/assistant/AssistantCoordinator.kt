package com.auralis.feature.assistant

import androidx.annotation.StringRes
import com.auralis.core.ai.AgentRunEvent
import com.auralis.core.ai.AgentToolLoop
import com.auralis.core.ai.AiProvider
import com.auralis.core.ai.AiProviderConfiguration
import com.auralis.core.ai.AiProviderException
import com.auralis.core.ai.AiProviderFailureKind
import com.auralis.core.ai.OpenAiCompatibleProvider
import com.auralis.core.ai.ToolSideEffect
import com.auralis.core.data.graph.AuralisGraph
import com.auralis.core.data.prefs.AiConnectionSettings
import com.auralis.core.designsystem.R as AuralisR
import java.util.UUID
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

/** AI 可用状态（Header 绿/黄标的数据源）。 */
data class AssistantAiStatus(
    val enabled: Boolean = true,
    val complete: Boolean = false,
    val model: String = "",
) {
    val isLive: Boolean get() = enabled && complete
}

/** 首次外发的用户选择。 */
enum class ConsentChoice { AllowOnce, AllowAndRemember, Cancel }

/**
 * Agent 编排层（对齐 Swift `AgentCoordinator` + `AgentMemoryStore` 的会话职责）。
 *
 * 铁律：
 * - 全局单运行（运行期间发送按钮为「停止」）；runID 迟到结果直接丢弃；
 * - 会话历史回灌只取 text 消息（reasoning/tool 进度/错误/确认均 transient，不入上下文）；
 * - 写操作授权 = 用户 consent（remembered 或 per-run once）；Destructive 工具逐次弹窗、
 *   确认绑定具体 runID（未批准 → fail closed 并如实回灌给模型）；
 * - 流式增量不写盘，仅最终 assistant 文本定稿落盘（agent-sessions.json）。
 */
class AssistantCoordinator(
    private val graph: AuralisGraph,
    private val scope: CoroutineScope,
) {
    private val store = AssistantSessionStore(graph.appContext)
    private val host = AssistantToolHost(graph)
    private val vault get() = graph.vault
    private val prefs get() = graph.preferences

    /** 模块资源取值（非 Composable / 协程上下文统一入口）。 */
    private fun stringRes(@StringRes res: Int, vararg args: Any): String =
        graph.appContext.getString(res, *args)

    /** 工具显示名（UI 工具行 / 操作日志摘要）；未知工具回退原名。 */
    private fun toolLabel(name: String): String =
        AssistantToolHost.toolLabelRes(name)?.let { stringRes(it) } ?: name

    private val writeToolNames: Set<String> =
        host.registry().descriptors().filter { it.sideEffect == ToolSideEffect.Write }.map { it.name }.toSet()

    // ------------------------------------------------------------- 状态

    private val _sessions = MutableStateFlow<List<AssistantSession>>(emptyList())
    val sessions: StateFlow<List<AssistantSession>> = _sessions.asStateFlow()

    private val _activeSessionId = MutableStateFlow<String?>(null)
    val activeSessionId: StateFlow<String?> = _activeSessionId.asStateFlow()

    private val _activeMessages = MutableStateFlow<List<StoredAssistantMessage>>(emptyList())
    val activeMessages: StateFlow<List<StoredAssistantMessage>> = _activeMessages.asStateFlow()

    val showArchived = MutableStateFlow(false)

    private val _aiStatus = MutableStateFlow(AssistantAiStatus())
    val aiStatus: StateFlow<AssistantAiStatus> = _aiStatus.asStateFlow()

    private val _run = MutableStateFlow(AssistantRunPresentation())
    val run: StateFlow<AssistantRunPresentation> = _run.asStateFlow()

    private val _consent = MutableStateFlow<ConsentRequest?>(null)
    val consent: StateFlow<ConsentRequest?> = _consent.asStateFlow()

    private val _confirm = MutableStateFlow<OperationConfirmRequest?>(null)
    val confirm: StateFlow<OperationConfirmRequest?> = _confirm.asStateFlow()

    private val _actions = MutableStateFlow<List<AssistantActionRecord>>(emptyList())
    val actions: StateFlow<List<AssistantActionRecord>> = _actions.asStateFlow()

    private val _lastError = MutableStateFlow<String?>(null)
    val lastError: StateFlow<String?> = _lastError.asStateFlow()

    private var consentDeferred: CompletableDeferred<ConsentChoice>? = null
    private var confirmDeferred: CompletableDeferred<Boolean>? = null
    private var currentRunId: String? = null
    private var runJob: Job? = null

    init {
        // 冷启动恢复：载入会话 + 操作日志，并持续观察 AI 开关/配置。
        scope.launch {
            val loaded = store.loadSessions().sortedWith(compareByDescending<AssistantSession> { it.isPinned }
                .thenByDescending { it.updatedAtMillis })
            _sessions.value = loaded
            _actions.value = store.loadActions()
            val first = loaded.firstOrNull { !it.isArchived } ?: loaded.firstOrNull()
            if (first != null) selectSession(first.id)
        }
        scope.launch {
            prefs.aiEnabledFlow.collect { enabled ->
                val settings = prefs.aiConnectionValue()
                _aiStatus.value = AssistantAiStatus(enabled = enabled, complete = settings.isComplete, model = settings.model)
            }
        }
    }

    // ------------------------------------------------------------- 会话管理

    fun visibleSessions(): List<AssistantSession> {
        val showAll = showArchived.value
        return _sessions.value
            .filter { showAll || !it.isArchived }
            .sortedWith(compareByDescending<AssistantSession> { it.isPinned }.thenByDescending { it.updatedAtMillis })
    }

    fun selectSession(id: String) {
        _activeSessionId.value = id
        pushActiveMessages()
    }

    fun newSession() {
        val now = System.currentTimeMillis()
        val session = AssistantSession(
            id = UUID.randomUUID().toString(),
            title = "",
            createdAtMillis = now,
            updatedAtMillis = now,
        )
        scope.launch {
            store.insertSession(session)
            _sessions.value = listOf(session) + _sessions.value
            selectSession(session.id)
        }
    }

    fun renameSession(id: String, title: String) {
        val trimmed = title.trim()
        scope.launch {
            updateSession(id) { it.copy(title = trimmed) }
        }
    }

    fun togglePin(id: String) = scope.launch { updateSession(id) { it.copy(isPinned = !it.isPinned) } }

    fun toggleArchived(id: String) = scope.launch { updateSession(id) { it.copy(isArchived = !it.isArchived) } }

    fun clearSessionMessages(id: String) = scope.launch {
        store.clearMessages(id)
        updateSession(id) { it.copy(messages = emptyList()) }
        pushActiveMessages()
    }

    fun deleteSession(id: String) = scope.launch {
        store.deleteSession(id)
        _sessions.value = _sessions.value.filterNot { it.id == id }
        if (_activeSessionId.value == id) {
            val next = visibleSessions().firstOrNull()
            if (next != null) selectSession(next.id) else {
                _activeSessionId.value = null
                _activeMessages.value = emptyList()
            }
        }
    }

    private suspend fun updateSession(id: String, transform: (AssistantSession) -> AssistantSession) {
        val current = _sessions.value.firstOrNull { it.id == id } ?: return
        val updated = transform(current).let { it.copy(updatedAtMillis = System.currentTimeMillis()) }
        store.saveSession(updated)
        _sessions.value = _sessions.value.map { if (it.id == id) updated else it }
        pushActiveMessages()
    }

    private fun pushActiveMessages() {
        val id = _activeSessionId.value
        _activeMessages.value = _sessions.value.firstOrNull { it.id == id }?.messages ?: emptyList()
    }

    // ------------------------------------------------------------- 发送 / 停止

    val isRunning: Boolean get() = _run.value.isRunning

    fun send(draft: String) {
        val text = draft.trim()
        if (text.isEmpty() || isRunning) return
        runJob?.cancel()
        runJob = scope.launch { runSend(text) }
    }

    fun stop() {
        runJob?.cancel()
        if (currentRunId != null) {
            currentRunId = null
            _run.value = AssistantRunPresentation()
            _confirm.value = null
            confirmDeferred?.complete(false)
            confirmDeferred = null
        }
    }

    /**
     * R4：播放页引导会话（由此继续播放 / 歌曲鉴赏）。
     *
     * 对齐 Swift `newSession() + cancelAssistant + send(intent)` 的组合语义：
     * 1. 若正在运行先停止；
     * 2. 创建**干净**新会话并激活（避免污染用户当前对话）；
     * 3. 立刻把 [seed] 作为用户消息发送。
     *
     * 调用方（Shell）应先把界面切到 Assistant 分区，使 consent / 确认对话框可见。
     * 内部用 [runSend] 同一路径，AI 关闭/未配置时错误照常落入 lastError。
     */
    fun startGuidedSession(seed: String) {
        if (isRunning) stop()
        scope.launch {
            createSessionFor(seed) // 同步在内存创建并激活；房间落盘
            runSend(seed)
        }
    }

    fun clearLastError() {
        _lastError.value = null
    }

    private suspend fun runSend(text: String) {
        _lastError.value = null
        val status = _aiStatus.value
        val settings = prefs.aiConnectionValue()
        if (!status.enabled) {
            _lastError.value = stringRes(R.string.assistant_err_disabled)
            return
        }
        if (!settings.isComplete) {
            _lastError.value = stringRes(R.string.assistant_err_config_incomplete)
            return
        }

        // ---- 首次外发确认（允许一次 / 允许并记住 / 取消）----
        if (!prefs.aiConsentGivenValue()) {
            val choice = requestConsent(ConsentRequest(modelName = settings.model, detail = stringRes(R.string.assistant_consent_detail)))
            when (choice) {
                ConsentChoice.Cancel -> {
                    _lastError.value = stringRes(R.string.assistant_err_no_permission)
                    return
                }
                ConsentChoice.AllowAndRemember -> prefs.setAiConsentGiven(true)
                ConsentChoice.AllowOnce -> Unit
            }
        }

        // ---- 准备会话（标题为空则以首条消息命名）----
        val sessionId = _activeSessionId.value ?: createSessionFor(text)
        val session = _sessions.value.firstOrNull { it.id == sessionId } ?: return
        if (session.title.isBlank()) {
            updateSession(sessionId) { it.copy(title = text.take(28)) }
        }
        // 用户消息立即定稿落盘（对齐 Swift：用户消息发送即持久化）。
        val userMessage = StoredAssistantMessage(StoredAssistantMessage.Role.User, text, System.currentTimeMillis())
        store.appendMessage(sessionId, userMessage)
        _sessions.value = _sessions.value.map { s ->
            if (s.id == sessionId) s.copy(messages = s.messages + userMessage, updatedAtMillis = System.currentTimeMillis()) else s
        }
        pushActiveMessages()

        // ---- 组装 Provider 并运行工具循环 ----
        val runId = UUID.randomUUID().toString()
        currentRunId = runId
        _run.value = AssistantRunPresentation(running = true, phase = AssistantRunPhase.Connecting)
        try {
            val provider = buildProvider(settings)
            val loop = AgentToolLoop(provider, host.registry(), maxRounds = 8)
            val result = loop.run(
                systemPrompt = SYSTEM_PROMPT,
                userText = text,
                model = settings.model,
                authorizeOperations = writeToolNames,
                confirm = { confirmation ->
                    requestConfirm(runId, confirmation.title, confirmation.detail, destructive = true)
                },
                onEvent = { event -> handleRunEvent(runId, event) },
            )
            if (currentRunId != runId) return // 迟到结果丢弃
            val answer = result.finalAnswer.trim()
            if (answer.isNotEmpty()) {
                val assistantMessage = StoredAssistantMessage(StoredAssistantMessage.Role.Assistant, answer, System.currentTimeMillis())
                store.appendMessage(sessionId, assistantMessage)
                _sessions.value = _sessions.value.map { s ->
                    if (s.id == sessionId) s.copy(messages = s.messages + assistantMessage, updatedAtMillis = System.currentTimeMillis()) else s
                }
                pushActiveMessages()
            }
            logActions(result.writeOperations)
        } catch (c: CancellationException) {
            // 用户停止：不落盘任何半成品。
        } catch (e: AiProviderException) {
            _lastError.value = describeProviderFailure(e)
        } catch (e: Exception) {
            _lastError.value = e.message ?: stringRes(R.string.assistant_err_request_failed)
        } finally {
            if (currentRunId == runId) {
                currentRunId = null
                _run.value = AssistantRunPresentation()
                _confirm.value = null
                consentDeferred = null
            }
        }
    }

    private suspend fun createSessionFor(text: String): String {
        val now = System.currentTimeMillis()
        val session = AssistantSession(
            id = UUID.randomUUID().toString(),
            title = text.take(28),
            createdAtMillis = now,
            updatedAtMillis = now,
        )
        store.insertSession(session)
        _sessions.value = listOf(session) + _sessions.value
        _activeSessionId.value = session.id
        pushActiveMessages()
        return session.id
    }

    // ------------------------------------------------------------- run 事件

    private fun handleRunEvent(runId: String, event: AgentRunEvent) {
        if (currentRunId != runId) return
        val current = _run.value
        when (event) {
            is AgentRunEvent.AssistantText -> _run.value = current.copy(phase = AssistantRunPhase.Responding)
            is AgentRunEvent.Reasoning -> _run.value = current.copy(phase = AssistantRunPhase.Thinking)
            is AgentRunEvent.ToolInvoked -> {
                _run.value = current.copy(
                    phase = AssistantRunPhase.Working,
                    liveItems = current.liveItems + AssistantLiveItem.ToolStatus(
                        toolName = event.call.name,
                        label = toolLabel(event.call.name),
                        state = AssistantLiveItem.ToolStatus.State.Running,
                    ),
                )
            }
            is AgentRunEvent.ToolCompleted -> updateToolStatus(runId, event.call.name, AssistantLiveItem.ToolStatus.State.Succeeded)
            is AgentRunEvent.ToolDenied -> updateToolStatus(runId, event.call.name, AssistantLiveItem.ToolStatus.State.Denied, event.reason)
            AgentRunEvent.Finished -> _run.value = _run.value.copy(phase = AssistantRunPhase.Responding)
        }
    }

    private fun updateToolStatus(runId: String, toolName: String, state: AssistantLiveItem.ToolStatus.State, detail: String? = null) {
        if (currentRunId != runId) return
        val current = _run.value
        val items = current.liveItems.mapIndexed { index, item ->
            if (item is AssistantLiveItem.ToolStatus && item.toolName == toolName && item.state == AssistantLiveItem.ToolStatus.State.Running) {
                AssistantLiveItem.ToolStatus(item.toolName, item.label, state, detail ?: item.detail)
            } else {
                item
            }
        }
        _run.value = current.copy(liveItems = items)
    }

    private suspend fun logActions(operations: List<com.auralis.core.ai.AiToolCall>) {
        if (operations.isEmpty()) return
        val records = operations.map { call ->
            AssistantActionRecord(
                id = UUID.randomUUID().toString(),
                operation = call.name,
                summary = toolLabel(call.name),
                createdAtMillis = System.currentTimeMillis(),
                reversible = call.name in AssistantToolHost.INVERSE_TOOL,
                argumentsJson = call.rawArguments,
            )
        }
        records.forEach { store.appendAction(it) }
        _actions.value = records + _actions.value
    }

    // ------------------------------------------------------------- consent / confirm

    private suspend fun requestConsent(request: ConsentRequest): ConsentChoice {
        _consent.value = request
        val deferred = CompletableDeferred<ConsentChoice>()
        consentDeferred = deferred
        return try {
            deferred.await()
        } finally {
            _consent.value = null
            consentDeferred = null
        }
    }

    fun allowOnce() {
        consentDeferred?.complete(ConsentChoice.AllowOnce)
    }

    fun allowAndRemember() {
        consentDeferred?.complete(ConsentChoice.AllowAndRemember)
    }

    fun cancelConsent() {
        consentDeferred?.complete(ConsentChoice.Cancel)
    }

    private suspend fun requestConfirm(runId: String, title: String, detail: String, destructive: Boolean): Boolean {
        _confirm.value = OperationConfirmRequest(runId = runId, title = title, detail = detail, destructive = destructive)
        val deferred = CompletableDeferred<Boolean>()
        confirmDeferred = deferred
        return try {
            deferred.await()
        } finally {
            if (_confirm.value?.runId == runId) _confirm.value = null
            confirmDeferred = null
        }
    }

    fun approveConfirm() {
        confirmDeferred?.complete(true)
    }

    fun rejectConfirm() {
        confirmDeferred?.complete(false)
    }

    // ------------------------------------------------------------- 操作日志撤销

    fun undoAction(record: AssistantActionRecord) {
        scope.launch {
            runCatching {
                val result = host.undo(record)
                store.removeAction(record.id)
                _actions.value = _actions.value.filterNot { it.id == record.id }
                val sessionId = _activeSessionId.value ?: return@runCatching
                val message = StoredAssistantMessage(
                    StoredAssistantMessage.Role.Assistant,
                    "已撤销「${record.summary}」：$result",
                    System.currentTimeMillis(),
                )
                store.appendMessage(sessionId, message)
                _sessions.value = _sessions.value.map { s ->
                    if (s.id == sessionId) s.copy(messages = s.messages + message, updatedAtMillis = System.currentTimeMillis()) else s
                }
                pushActiveMessages()
            }.onFailure { e ->
                _lastError.value = stringRes(R.string.assistant_undo_failed, e.message ?: stringRes(AuralisR.string.unknown_error))
            }
        }
    }

    // ------------------------------------------------------------- 组装 Provider

    private suspend fun buildProvider(settings: AiConnectionSettings): AiProvider {
        val apiKey = vault.retrieve(AiConnectionSettings.API_KEY_REFERENCE)
        val configuration = AiProviderConfiguration(
            id = "ai.provider",
            name = "OpenAI 兼容",
            baseUrl = settings.baseUrl,
            apiPath = settings.apiPath,
            credentialId = AiConnectionSettings.API_KEY_REFERENCE,
            model = settings.model,
            maxTokens = settings.maxOutputTokens,
            maxContextTokens = settings.maxContextTokens,
            hasKnownContextWindow = false,
            usesStreaming = true,
            supportsToolCalling = settings.supportsToolCalling,
            supportsParallelTools = false,
            supportsToolChoice = false,
        )
        return OpenAiCompatibleProvider(configuration, apiKeyProvider = { apiKey })
    }

    private fun describeProviderFailure(e: AiProviderException): String {
        val label = when (e.kind) {
            AiProviderFailureKind.Authentication -> stringRes(R.string.assistant_provider_error_auth)
            AiProviderFailureKind.ModelRouting, AiProviderFailureKind.UpstreamRouting -> stringRes(R.string.assistant_provider_error_routing)
            AiProviderFailureKind.RateLimited -> stringRes(R.string.assistant_provider_error_rate_limited)
            AiProviderFailureKind.IncompatibleRequest -> stringRes(R.string.assistant_provider_error_incompatible)
            AiProviderFailureKind.ProviderUnavailable -> stringRes(R.string.assistant_provider_error_unavailable)
            AiProviderFailureKind.Unknown -> stringRes(R.string.assistant_provider_error_unknown)
        }
        val detail = e.message?.takeIf { it.isNotBlank() }?.let { stringRes(R.string.assistant_error_detail_colon, it) } ?: ""
        return stringRes(R.string.assistant_provider_error_fmt, label, detail)
    }

    companion object {
        private val SYSTEM_PROMPT = """
            你是 Auralis（本地音乐库）的 AI 助手，通过工具操作真实的音乐库数据。
            规则：
            1. 回答前优先调用工具查询真实数据，绝不编造不存在的歌曲/专辑/艺人/歌单；
            2. 只读工具（搜索/查询/歌词）可随时调用；
            3. 写操作（播放、收藏、评分、歌单增删改）需要先向用户说明将执行的动作，再调用工具；
            4. 破坏性操作（删除歌单等）会弹窗让用户批准；若工具返回"用户取消"或"未获授权"，如实告知用户结果，不要重试绕过；
            5. 涉及歌曲请标注歌手与专辑；列表过长时只展示前几条并说明总数；
            6. 使用简体中文，简洁直接。
        """.trimIndent()
    }
}
