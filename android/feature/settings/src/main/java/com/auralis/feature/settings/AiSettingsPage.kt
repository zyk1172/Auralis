package com.auralis.feature.settings

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import com.auralis.core.ai.AiProviderConfiguration
import com.auralis.core.ai.AiProviderFailureKind
import com.auralis.core.ai.AiProviderException
import com.auralis.core.ai.OpenAiCompatibleProvider
import com.auralis.core.data.graph.AuralisGraph
import com.auralis.core.data.prefs.AiConnectionSettings
import com.auralis.core.designsystem.AuralisSpacing
import com.auralis.core.designsystem.LocalAuralisTheme
import com.auralis.core.designsystem.R as AuralisR
import kotlinx.coroutines.launch

/**
 * AI 助手设置页（对齐 Swift `AIProviderSettingsPage`，SettingsView.swift 附近 646+）。
 *
 * - 行项：AI 助手开关 / 接口地址(baseURL) / 接口路径(apiPath) / 模型 / API Key /
 *   上下文窗口 / 单次输出上限 / 原生工具调用 / 外发授权撤销；
 * - API Key 只存系统安全存储（Keystore，reference 对齐 Swift credentialID
 *   "ai.provider.api-key"），绝不写入 DataStore；
 * - 「保存」写本地偏好（对齐 Swift 实时绑定，Android 用显式保存避免半输入态）；
 * - 「测试连接」真实调用 OpenAI 兼容端点 testConnection，绿勾/红叉如实呈现。
 */
@Composable
fun AiSettingsPage(
    graph: AuralisGraph,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = LocalAuralisTheme.current.colors
    val scope = rememberCoroutineScope()
    val context = LocalContext.current.applicationContext

    var enabled by remember { mutableStateOf(true) }
    var consentGiven by remember { mutableStateOf(false) }
    var apiKeySaved by remember { mutableStateOf(false) }

    var baseUrl by remember { mutableStateOf("") }
    var apiPath by remember { mutableStateOf("") }
    var model by remember { mutableStateOf("") }
    var maxContext by remember { mutableStateOf("") }
    var maxOutput by remember { mutableStateOf("") }
    var toolCalling by remember { mutableStateOf(true) }
    var apiKeyInput by remember { mutableStateOf("") }

    var savedNotice by remember { mutableStateOf<String?>(null) }
    var testState by remember { mutableStateOf<Pair<String, Boolean>?>(null) } // (text, isSuccess)

    LaunchedEffect(Unit) {
        val prefs = graph.preferences
        enabled = prefs.aiEnabledValue()
        consentGiven = prefs.aiConsentGivenValue()
        val settings = prefs.aiConnectionValue()
        baseUrl = settings.baseUrl
        apiPath = settings.apiPath
        model = settings.model
        maxContext = settings.maxContextTokens.toString()
        maxOutput = settings.maxOutputTokens.toString()
        toolCalling = settings.supportsToolCalling
        apiKeySaved = graph.vault.retrieve(AiConnectionSettings.API_KEY_REFERENCE) != null
    }

    fun currentSettings(): AiConnectionSettings = AiConnectionSettings(
        baseUrl = baseUrl,
        apiPath = apiPath,
        model = model,
        maxContextTokens = maxContext.toIntOrNull() ?: AiConnectionSettings.DEFAULT_MAX_CONTEXT_TOKENS,
        maxOutputTokens = maxOutput.toIntOrNull() ?: AiConnectionSettings.DEFAULT_MAX_OUTPUT_TOKENS,
        supportsToolCalling = toolCalling,
    )

    fun save() {
        scope.launch {
            val prefs = graph.preferences
            prefs.setAiEnabled(enabled)
            prefs.setAiBaseUrl(baseUrl)
            prefs.setAiApiPath(apiPath)
            prefs.setAiModel(model)
            prefs.setAiMaxContextTokens(maxContext.toIntOrNull() ?: AiConnectionSettings.DEFAULT_MAX_CONTEXT_TOKENS)
            prefs.setAiMaxOutputTokens(maxOutput.toIntOrNull() ?: AiConnectionSettings.DEFAULT_MAX_OUTPUT_TOKENS)
            prefs.setAiSupportsToolCalling(toolCalling)
            if (apiKeyInput.isNotBlank()) {
                graph.vault.store(AiConnectionSettings.API_KEY_REFERENCE, apiKeyInput.trim())
                apiKeyInput = ""
                apiKeySaved = true
            }
            savedNotice = context.getString(R.string.settings_ai_saved_notice)
            testState = null
        }
    }

    fun testConnection() {
        val settings = currentSettings()
        if (!settings.isComplete) {
            testState = context.getString(R.string.settings_ai_incomplete) to false
            return
        }
        scope.launch {
            testState = null
            savedNotice = null
            runCatching {
                val config = AiProviderConfiguration(
                    id = "ai.provider.test",
                    name = context.getString(R.string.settings_ai_openai_compatible),
                    baseUrl = settings.baseUrl,
                    apiPath = settings.apiPath,
                    credentialId = AiConnectionSettings.API_KEY_REFERENCE,
                    model = settings.model,
                    maxTokens = settings.maxOutputTokens,
                    maxContextTokens = settings.maxContextTokens,
                    hasKnownContextWindow = false,
                    usesStreaming = true,
                    supportsToolCalling = settings.supportsToolCalling,
                )
                val apiKey = graph.vault.retrieve(AiConnectionSettings.API_KEY_REFERENCE)
                val provider = OpenAiCompatibleProvider(config, apiKeyProvider = { apiKey })
                provider.testConnection()
            }.onSuccess { result ->
                val diagnostic = result.diagnostics?.let {
                    context.getString(R.string.settings_ai_diagnostics_format, it.streaming.name, it.nativeTools.name)
                } ?: ""
                testState = context.getString(R.string.settings_ai_connect_success, result.model, result.latencyMillis, diagnostic).trim() to true
            }.onFailure { e ->
                val reason = when (e) {
                    is AiProviderException -> when (e.kind) {
                        AiProviderFailureKind.Authentication -> context.getString(R.string.settings_ai_error_auth)
                        AiProviderFailureKind.ModelRouting, AiProviderFailureKind.UpstreamRouting -> context.getString(R.string.settings_ai_error_routing)
                        AiProviderFailureKind.RateLimited -> context.getString(R.string.settings_ai_error_rate_limited)
                        AiProviderFailureKind.IncompatibleRequest -> context.getString(R.string.settings_ai_error_incompatible, e.message)
                        AiProviderFailureKind.ProviderUnavailable -> context.getString(R.string.settings_ai_error_unavailable)
                        AiProviderFailureKind.Unknown -> context.getString(R.string.settings_ai_error_unknown, e.message)
                    }
                    else -> e.message ?: context.getString(R.string.settings_ai_test_failed)
                }
                testState = context.getString(R.string.settings_ai_connect_failed, reason) to false
            }
        }
    }

    SettingsPageContainer(modifier = modifier) {
        LazyColumn(modifier = Modifier.fillMaxSize()) {
            item { SettingsDetailTopBar(title = stringResource(R.string.settings_ai_title), onBack = onBack) }
            item {
                Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth().padding(vertical = AuralisSpacing.small)) {
                    Column(modifier = Modifier.weight(1f)) {
                        Text(stringResource(R.string.settings_ai_enable), style = MaterialTheme.typography.bodyLarge, color = colors.primaryText)
                        Text(
                            stringResource(if (consentGiven) R.string.settings_ai_consent_granted_subtitle else R.string.settings_ai_consent_pending_subtitle),
                            style = MaterialTheme.typography.bodySmall,
                            color = colors.secondaryText,
                        )
                    }
                    Switch(checked = enabled, onCheckedChange = {
                        enabled = it
                        savedNotice = null
                    })
                }
            }
            item { SettingsSectionTitle(stringResource(R.string.settings_ai_api_section)) }
            item { FieldLabel(stringResource(R.string.settings_ai_base_url_label)) }
            item {
                OutlinedTextField(value = baseUrl, onValueChange = { baseUrl = it; savedNotice = null }, singleLine = true, modifier = Modifier.fillMaxWidth())
            }
            item { FieldLabel(stringResource(R.string.settings_ai_api_path_label)) }
            item {
                OutlinedTextField(value = apiPath, onValueChange = { apiPath = it; savedNotice = null }, singleLine = true, modifier = Modifier.fillMaxWidth())
            }
            item { FieldLabel(stringResource(R.string.settings_ai_model_label)) }
            item {
                OutlinedTextField(value = model, onValueChange = { model = it; savedNotice = null }, singleLine = true, modifier = Modifier.fillMaxWidth())
            }
            item { FieldLabel("API Key") }
            item {
                OutlinedTextField(
                    value = apiKeyInput,
                    onValueChange = { apiKeyInput = it; savedNotice = null },
                    singleLine = true,
                    visualTransformation = PasswordVisualTransformation(),
                    placeholder = { Text(stringResource(if (apiKeySaved) R.string.settings_ai_key_placeholder_saved else R.string.settings_ai_key_placeholder_new)) },
                    modifier = Modifier.fillMaxWidth(),
                )
            }
            item {
                SettingsCaption(stringResource(R.string.settings_ai_key_caption))
            }
            item { SettingsSectionTitle(stringResource(R.string.settings_ai_advanced_section)) }
            item { FieldLabel(stringResource(R.string.settings_ai_context_label)) }
            item {
                OutlinedTextField(
                    value = maxContext,
                    onValueChange = { maxContext = it.filter(Char::isDigit); savedNotice = null },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                    modifier = Modifier.fillMaxWidth(),
                )
            }
            item { FieldLabel(stringResource(R.string.settings_ai_output_label)) }
            item {
                OutlinedTextField(
                    value = maxOutput,
                    onValueChange = { maxOutput = it.filter(Char::isDigit); savedNotice = null },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                    modifier = Modifier.fillMaxWidth(),
                )
            }
            item {
                Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth().padding(vertical = AuralisSpacing.small)) {
                    Column(modifier = Modifier.weight(1f)) {
                        Text(stringResource(R.string.settings_ai_tool_title), style = MaterialTheme.typography.bodyLarge, color = colors.primaryText)
                        Text(stringResource(R.string.settings_ai_tool_note), style = MaterialTheme.typography.bodySmall, color = colors.secondaryText)
                    }
                    Switch(checked = toolCalling, onCheckedChange = { toolCalling = it; savedNotice = null })
                }
            }
            item {
                Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth().padding(vertical = AuralisSpacing.small)) {
                    Column(modifier = Modifier.weight(1f)) {
                        Text(stringResource(R.string.settings_ai_consent_title), style = MaterialTheme.typography.bodyLarge, color = colors.primaryText)
                        Text(stringResource(if (consentGiven) R.string.settings_ai_consent_granted_note else R.string.settings_ai_consent_pending_note), style = MaterialTheme.typography.bodySmall, color = colors.secondaryText)
                    }
                    if (consentGiven) {
                        TextButton(onClick = {
                            scope.launch {
                                graph.preferences.setAiConsentGiven(false)
                                consentGiven = false
                                savedNotice = context.getString(R.string.settings_ai_consent_revoked_notice)
                            }
                        }) { Text(stringResource(R.string.settings_ai_revoke)) }
                    }
                }
            }
            item {
                Row(modifier = Modifier.fillMaxWidth().padding(vertical = AuralisSpacing.small)) {
                    Button(onClick = ::save, modifier = Modifier.weight(1f)) { Text(stringResource(AuralisR.string.save)) }
                    Spacer(Modifier.width(AuralisSpacing.medium))
                    OutlinedButton(
                        onClick = ::testConnection,
                        enabled = currentSettings().isComplete,
                        modifier = Modifier.weight(1f),
                    ) { Text(stringResource(AuralisR.string.test_connection)) }
                }
            }
            savedNotice?.let { notice ->
                item { Text(notice, style = MaterialTheme.typography.bodyMedium, color = colors.success) }
            }
            testState?.let { (text, success) ->
                item {
                    Text(text, style = MaterialTheme.typography.bodyMedium, color = if (success) colors.success else colors.error)
                }
            }
            item { SettingsSectionTitle(stringResource(R.string.settings_ai_about_section)) }
            item {
                SettingsCaption(stringResource(R.string.settings_ai_privacy_note))
            }
            item { Spacer(Modifier.height(AuralisSpacing.large)) }
        }
    }
}

@Composable
private fun FieldLabel(text: String) {
    val colors = LocalAuralisTheme.current.colors
    Text(
        text,
        style = MaterialTheme.typography.labelLarge,
        color = colors.secondaryText,
        modifier = Modifier.padding(top = AuralisSpacing.small, bottom = AuralisSpacing.xSmall),
    )
}
