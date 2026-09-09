// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.core.ai

import okhttp3.OkHttpClient

/**
 * 根据用户配置的 API path 选择实际 wire protocol。
 *
 * Auralis 允许同一组 baseURL/apiPath/model 配置指向三种原生协议：
 * - Chat Completions → [OpenAiCompatibleProvider]
 * - Responses → [OpenAiResponsesProvider]
 * - Anthropic Messages → [AnthropicMessagesProvider]
 *
 * 协议选择必须发生在 Provider 构造边界，设置页「测试连接」与真正 Assistant run 共用
 * 同一工厂，避免测试成功后运行时又落到另一套 wire codec。
 */
object AiProviderFactory {
    fun create(
        configuration: AiProviderConfiguration,
        apiKeyProvider: suspend () -> String?,
        client: OkHttpClient? = null,
    ): AiProvider {
        val path = configuration.apiPath.trim().lowercase()
        return when {
            path == "responses" || path == "/responses" || path.endsWith("/responses") ->
                OpenAiResponsesProvider(configuration, apiKeyProvider, client)

            path == "messages" || path == "/messages" || path.endsWith("/messages") ->
                AnthropicMessagesProvider(configuration, apiKeyProvider, client)

            else -> OpenAiCompatibleProvider(configuration, apiKeyProvider, client)
        }
    }
}
