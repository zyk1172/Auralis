package com.auralis.feature.assistant

import kotlinx.serialization.Serializable

// ---------------------------------------------------------------------------
// 会话/消息持久化模型（对齐 Swift AgentSession/AgentChatMessage；JSON 落盘）
// ---------------------------------------------------------------------------

@Serializable
data class AssistantSession(
    val id: String,
    val title: String,
    val messages: List<StoredAssistantMessage> = emptyList(),
    val createdAtMillis: Long,
    val updatedAtMillis: Long,
    val isPinned: Boolean = false,
    val isArchived: Boolean = false,
) {
    val displayTitle: String get() = title.ifBlank { "新会话" }
}

/** 落盘消息 = 角色 + 纯文本。reasoning/toolProgress/error 等 transient 内容不写盘（对齐 Swift）。 */
@Serializable
data class StoredAssistantMessage(
    val role: Role,
    val text: String,
    val createdAtMillis: Long,
) {
    enum class Role { User, Assistant }
}

@Serializable
internal data class AssistantStoreFile(
    val version: Int = 1,
    val sessions: List<AssistantSession> = emptyList(),
)

// ---------------------------------------------------------------------------
// 运行呈现状态（对齐 Swift AssistantRunPresentationState；transient 仅内存）
// ---------------------------------------------------------------------------

enum class AssistantRunPhase(val displayText: String) {
    Connecting("正在连接模型…"),
    Thinking("思考中…"),
    Working("执行操作…"),
    Responding("正在回复…"),
}

/** 运行中会瞬态展示的一条内容。 */
sealed interface AssistantLiveItem {
    /** 模型思考文本：只展示，绝不持久化、绝不进上下文。 */
    data class Reasoning(val text: String) : AssistantLiveItem

    /** 工具执行状态行。 */
    data class ToolStatus(
        val toolName: String,
        val label: String,
        val state: State,
        val detail: String? = null,
    ) : AssistantLiveItem {
        enum class State { Running, Succeeded, Denied }
    }
}

data class AssistantRunPresentation(
    val running: Boolean = false,
    val phase: AssistantRunPhase = AssistantRunPhase.Connecting,
    val liveItems: List<AssistantLiveItem> = emptyList(),
) {
    val isRunning: Boolean get() = running
}

// ---------------------------------------------------------------------------
// 隐私/确认请求（UI 弹窗的数据源；与具体 runID/请求绑定）
// ---------------------------------------------------------------------------

/** 首次外发确认（对齐 Swift pendingConsent：允许一次/允许并记住/取消）。 */
data class ConsentRequest(
    val modelName: String,
    val detail: String,
)

/** 写操作/破坏性操作确认（对齐 Swift pendingOperationConfirmation）。 */
data class OperationConfirmRequest(
    val runId: String,
    val title: String,
    val detail: String,
    /** true = Destructive（按钮红色强调）；false = 普通写操作补充确认。 */
    val destructive: Boolean,
)

/** 操作日志条目（对齐 agent.actionRecords；可撤销项提供真实逆向操作）。 */
@Serializable
data class AssistantActionRecord(
    val id: String,
    val operation: String,
    val summary: String,
    val createdAtMillis: Long,
    val reversible: Boolean,
    /** 序列化的参数 JSON（逆向执行用）。 */
    val argumentsJson: String,
) {
    val isReversible: Boolean get() = reversible
}
