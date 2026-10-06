// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
package com.auralis.feature.assistant

import com.auralis.core.ai.AiMessage
import com.auralis.core.ai.AiPrivacyCategory
import com.auralis.core.ai.AiPrivacyPermissions
import com.auralis.core.data.prefs.AiPrivacyPermissionFlags

// ---------------------------------------------------------------------------
// AI-05：会话历史 → 模型上下文的单一投影策略（对齐 Swift AgentHistoryPolicy）。
//
// 落盘消息只含用户消息与助手定稿正文（进度/错误碎片/旧确认本就 transient 不落盘），
// 因此投影只需做两件事：
// 1. 角色映射（User→user, Assistant→assistant），空正文丢弃；
// 2. 已标记助手正文按来源类别过滤；旧数据无来源时只在全部类别允许时重放。
//
// 跨会话隔离：调用方只传当前会话的 messages；删除会话后存储无残留。
// ---------------------------------------------------------------------------

object AssistantHistoryProjection {

    /** core:data 中立开关 → core:ai 披露权限模型的映射。 */
    fun AiPrivacyPermissionFlags.toAiPermissions(): AiPrivacyPermissions = AiPrivacyPermissions(
        allowsMetadata = allowsMetadata,
        allowsLyrics = allowsLyrics,
        allowsPlaybackHistory = allowsPlaybackHistory,
        allowsFavoritesAndRatings = allowsFavoritesAndRatings,
        allowsExternalDiscovery = allowsExternalDiscovery,
    )

    /**
     * 把当前会话的落盘消息投影为模型历史。
     * 调用方负责剔除「当前正在发送」的最后一条用户消息（它作为 userText 单独传递）。
     */
    fun modelMessages(
        messages: List<StoredAssistantMessage>,
        permissions: AiPrivacyPermissions,
    ): List<AiMessage> = messages.mapNotNull { message ->
        val text = message.text.trim()
        if (text.isEmpty()) return@mapNotNull null
        when (message.role) {
            StoredAssistantMessage.Role.User ->
                AiMessage(AiMessage.Role.User, text)

            StoredAssistantMessage.Role.Assistant ->
                if (message.disclosureCategories?.all(permissions::allows) ?: permissions.allowPersistedAssistantText) {
                    AiMessage(AiMessage.Role.Assistant, text,
                        disclosureCategories = message.disclosureCategories ?: AiPrivacyCategory.entries.toSet())
                } else {
                    // Tagged messages are filtered by their actual source; legacy prose remains conservative.
                    null
                }
        }
    }
}
