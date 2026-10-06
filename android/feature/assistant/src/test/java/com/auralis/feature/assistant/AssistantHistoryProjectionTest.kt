// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
package com.auralis.feature.assistant

import com.auralis.core.ai.AiMessage
import com.auralis.core.ai.AiPrivacyPermissions
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * AI-05/AI-12：会话历史投影 —— 两轮选歌与「第三首」引用、连续「继续」、
 * 跨会话隔离（只投影传入的当前会话）、披露权限对助手正文的约束。
 */
class AssistantHistoryProjectionTest {

    private var tick = 0L

    private fun user(text: String) = StoredAssistantMessage(
        StoredAssistantMessage.Role.User, text, ++tick,
    )

    private fun assistant(text: String) = StoredAssistantMessage(
        StoredAssistantMessage.Role.Assistant, text, ++tick,
    )

    private val allOpen = AiPrivacyPermissions(
        allowsExternalDiscovery = true,
        allowsLyrics = true,
        allowsPlaybackHistory = true,
        allowsFavoritesAndRatings = true,
    )

    @Test
    fun `两轮选歌与第三首引用所需的历史全部投影`() {
        val messages = listOf(
            user("帮我选几首周杰伦"),
            assistant("已选：1.晴天 2.夜曲 3.稻香"),
            user("换成林俊杰"),
            assistant("已选：1.江南 2.曹操 3.小酒窝"),
        )
        val projected = AssistantHistoryProjection.modelMessages(messages, allOpen)
        assertEquals(4, projected.size)
        assertEquals(AiMessage.Role.User, projected[0].role)
        assertEquals(AiMessage.Role.Assistant, projected[1].role)
        assertEquals("换成林俊杰", projected[2].content)
        assertEquals("已选：1.江南 2.曹操 3.小酒窝", projected[3].content)
    }

    @Test
    fun `连续两次继续之间的新任务意图完整保留`() {
        val messages = listOf(
            user("帮我建一个雨天歌单"),
            assistant("好的，我先查一下本地库"),
            user("继续"),
            assistant("已找到 12 首候选"),
            user("继续"),
        )
        val projected = AssistantHistoryProjection.modelMessages(messages, allOpen)
        assertEquals(5, projected.size)
        assertEquals("帮我建一个雨天歌单", projected.first().content)
        assertEquals("继续", projected.last().content)
    }

    @Test
    fun `只投影传入的当前会话消息（跨会话不串消息）`() {
        val sessionA = listOf(user("会话A的请求"), assistant("会话A的回答"))
        val projected = AssistantHistoryProjection.modelMessages(sessionA, allOpen)
        assertEquals(2, projected.size)
        assertTrue(projected.all { !it.content.contains("会话B") })
    }

    @Test
    fun `披露类别关闭后助手正文不重放但用户消息保留`() {
        val messages = listOf(
            user("把私密收藏夹的歌整理一下"),
            assistant("你的收藏里有 42 首，评分最高的是《夜曲》"),
        )
        // 默认权限（本地披露类别全关）→ allowPersistedAssistantText = false。
        val projected = AssistantHistoryProjection.modelMessages(messages, AiPrivacyPermissions())
        assertEquals(1, projected.size)
        assertEquals(AiMessage.Role.User, projected[0].role)
        assertTrue(projected.none { it.content.contains("夜曲") })
        // 全部打开后助手正文恢复投影。
        val opened = AssistantHistoryProjection.modelMessages(messages, allOpen)
        assertEquals(2, opened.size)
    }

    @Test
    fun `空正文消息被丢弃`() {
        val messages = listOf(user("hi"), assistant("   "), user("继续"))
        val projected = AssistantHistoryProjection.modelMessages(messages, allOpen)
        assertEquals(2, projected.size)
        assertEquals("hi", projected[0].content)
        assertEquals("继续", projected[1].content)
    }
    @Test fun `known clean assistant text remains and revoked source is filtered`() {
        val clean = assistant("ordinary").copy(disclosureCategories = emptySet())
        val lyrics = assistant("private").copy(disclosureCategories = setOf(com.auralis.core.ai.AiPrivacyCategory.Lyrics))
        assertEquals(listOf("ordinary"), AssistantHistoryProjection.modelMessages(listOf(clean, lyrics), AiPrivacyPermissions()).map { it.content })
        assertEquals(setOf(com.auralis.core.ai.AiPrivacyCategory.Lyrics), AssistantHistoryProjection.modelMessages(listOf(lyrics), allOpen).single().disclosureCategories)
    }

}
