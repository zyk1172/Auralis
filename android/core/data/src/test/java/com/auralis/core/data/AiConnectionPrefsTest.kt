// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.core.data

import androidx.test.core.app.ApplicationProvider
import com.auralis.core.data.prefs.AiConnectionSettings
import com.auralis.core.data.prefs.AuralisPreferences
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** S8：AI 助手配置持久化（DataStore）+ isComplete 语义。 */
class AiConnectionPrefsTest : RoomDbTest() {

    @Test
    fun `默认值与 Swift 一致且可写后读回`() = runBlocking {
        val ctx = ApplicationProvider.getApplicationContext<android.content.Context>()
        val prefs = AuralisPreferences(ctx)

        // 默认：aiEnabled=true、consent 未给、OpenAI 默认连接。
        assertTrue(prefs.aiEnabledFlow.first())
        assertFalse(prefs.aiConsentGivenFlow.first())
        val defaults = prefs.aiConnectionFlow.first()
        assertEquals("https://api.openai.com", defaults.baseUrl)
        assertEquals("/v1/chat/completions", defaults.apiPath)
        assertEquals("gpt-4o-mini", defaults.model)
        assertEquals(256_000, defaults.maxContextTokens)
        assertEquals(16_000, defaults.maxOutputTokens)
        assertTrue(defaults.supportsToolCalling)

        prefs.setAiEnabled(false)
        prefs.setAiConsentGiven(true)
        prefs.setAiBaseUrl("http://localhost:11434")
        prefs.setAiApiPath("/v1/chat/completions")
        prefs.setAiModel("qwen2.5:7b")
        prefs.setAiMaxContextTokens(32_000)
        prefs.setAiMaxOutputTokens(4_000)
        prefs.setAiSupportsToolCalling(false)

        // 模拟重启：新实例必须读回。
        val second = AuralisPreferences(ctx)
        assertFalse(second.aiEnabledFlow.first())
        assertTrue(second.aiConsentGivenFlow.first())
        val saved = second.aiConnectionFlow.first()
        assertEquals("http://localhost:11434", saved.baseUrl)
        assertEquals("qwen2.5:7b", saved.model)
        assertEquals(32_000, saved.maxContextTokens)
        assertEquals(4_000, saved.maxOutputTokens)
        assertFalse(saved.supportsToolCalling)
        assertTrue(saved.isComplete)

        // 不完整配置 → isComplete=false（send 被 UI 禁用，不伪装）。
        val incomplete = saved.copy(baseUrl = "", model = " ")
        assertFalse(incomplete.isComplete)
    }
}
