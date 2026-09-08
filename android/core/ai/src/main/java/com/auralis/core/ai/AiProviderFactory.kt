// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.core.ai

import okhttp3.OkHttpClient

/**
 * 根据用户配置的 API path 选择实际 wire protocol。
 *
 * Auralis 允许同一「OpenAI 兼容」配置指向 Chat Completions 或 Responses；不能让
 * `/v1/responses` 继续落进 Chat provider 后以“不支持”结束。Anthropic `/messages`
 * 仍显式保留为尚未移植的协议，避免静默发错请求体。
 */
object AiProviderFactory {
    fun create(
        configuration: AiProviderConfiguration,
        apiKeyProvider: suspend () -> String?,
        client: OkHttpClient? = null,
    ): AiProvider {
        val path = configuration.apiPath.trim().lowercase()
        return if (path == "responses" || path == "/responses" || path.endsWith("/responses")) {
            OpenAiResponsesProvider(configuration, apiKeyProvider, client)
        } else {
            OpenAiCompatibleProvider(configuration, apiKeyProvider, client)
        }
    }
}
