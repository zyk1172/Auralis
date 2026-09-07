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
            savedNotice = "已保存到本机。"
            testState = null
        }
    }

    fun testConnection() {
        val settings = currentSettings()
        if (!settings.isComplete) {
            testState = "接口地址/接口路径/模型不完整，无法测试。" to false
            return
        }
        scope.launch {
            testState = null
            savedNotice = null
            runCatching {
                val config = AiProviderConfiguration(
                    id = "ai.provider.test",
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
                )
                val apiKey = graph.vault.retrieve(AiConnectionSettings.API_KEY_REFERENCE)
                val provider = OpenAiCompatibleProvider(config, apiKeyProvider = { apiKey })
                provider.testConnection()
            }.onSuccess { result ->
                val diagnostic = result.diagnostics?.let {
                    "流式:${it.streaming.name} 原生工具:${it.nativeTools.name}"
                } ?: ""
                testState = "连接成功：模型 ${result.model} · 延迟 ${result.latencyMillis}ms。$diagnostic".trim() to true
            }.onFailure { e ->
                val reason = when (e) {
                    is AiProviderException -> when (e.kind) {
                        AiProviderFailureKind.Authentication -> "鉴权失败（API Key 无效？）"
                        AiProviderFailureKind.ModelRouting, AiProviderFailureKind.UpstreamRouting -> "模型或上游路由问题（检查模型名/地址）"
                        AiProviderFailureKind.RateLimited -> "已被限流"
                        AiProviderFailureKind.IncompatibleRequest -> "请求不兼容：${e.message}"
                        AiProviderFailureKind.ProviderUnavailable -> "服务不可用或网络异常"
                        AiProviderFailureKind.Unknown -> "未知错误：${e.message}"
                    }
                    else -> e.message ?: "测试失败"
                }
                testState = "连接失败：$reason" to false
            }
        }
    }

    SettingsPageContainer(modifier = modifier) {
        LazyColumn(modifier = Modifier.fillMaxSize()) {
            item { SettingsDetailTopBar(title = "AI 助手", onBack = onBack) }
            item {
                Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth().padding(vertical = AuralisSpacing.small)) {
                    Column(modifier = Modifier.weight(1f)) {
                        Text("启用 AI 助手", style = MaterialTheme.typography.bodyLarge, color = colors.primaryText)
                        Text(
                            if (consentGiven) "已授权外发；可在下方撤销" else "首次对话需确认内容外发",
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
            item { SettingsSectionTitle("模型接口") }
            item { FieldLabel("接口地址 baseURL") }
            item {
                OutlinedTextField(value = baseUrl, onValueChange = { baseUrl = it; savedNotice = null }, singleLine = true, modifier = Modifier.fillMaxWidth())
            }
            item { FieldLabel("接口路径 apiPath") }
            item {
                OutlinedTextField(value = apiPath, onValueChange = { apiPath = it; savedNotice = null }, singleLine = true, modifier = Modifier.fillMaxWidth())
            }
            item { FieldLabel("模型 model") }
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
                    placeholder = { Text(if (apiKeySaved) "已保存（留空则不修改）" else "输入 API Key") },
                    modifier = Modifier.fillMaxWidth(),
                )
            }
            item {
                SettingsCaption("API Key 仅保存在系统安全存储（Keystore），不写入偏好设置。留空保存不会覆盖已存 Key。")
            }
            item { SettingsSectionTitle("高级") }
            item { FieldLabel("上下文窗口（tokens）") }
            item {
                OutlinedTextField(
                    value = maxContext,
                    onValueChange = { maxContext = it.filter(Char::isDigit); savedNotice = null },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                    modifier = Modifier.fillMaxWidth(),
                )
            }
            item { FieldLabel("单次输出上限（tokens）") }
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
                        Text("原生工具调用", style = MaterialTheme.typography.bodyLarge, color = colors.primaryText)
                        Text("关闭后 AI 只能问答，不能执行播放/收藏/歌单等操作", style = MaterialTheme.typography.bodySmall, color = colors.secondaryText)
                    }
                    Switch(checked = toolCalling, onCheckedChange = { toolCalling = it; savedNotice = null })
                }
            }
            item {
                Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth().padding(vertical = AuralisSpacing.small)) {
                    Column(modifier = Modifier.weight(1f)) {
                        Text("外发授权", style = MaterialTheme.typography.bodyLarge, color = colors.primaryText)
                        Text(if (consentGiven) "已允许把内容发送到模型服务商（本机记住）" else "尚未授权外发（首次对话会询问）", style = MaterialTheme.typography.bodySmall, color = colors.secondaryText)
                    }
                    if (consentGiven) {
                        TextButton(onClick = {
                            scope.launch {
                                graph.preferences.setAiConsentGiven(false)
                                consentGiven = false
                                savedNotice = "已撤销外发授权；下次对话将重新询问。"
                            }
                        }) { Text("撤销授权") }
                    }
                }
            }
            item {
                Row(modifier = Modifier.fillMaxWidth().padding(vertical = AuralisSpacing.small)) {
                    Button(onClick = ::save, modifier = Modifier.weight(1f)) { Text("保存") }
                    Spacer(Modifier.width(AuralisSpacing.medium))
                    OutlinedButton(
                        onClick = ::testConnection,
                        enabled = currentSettings().isComplete,
                        modifier = Modifier.weight(1f),
                    ) { Text("测试连接") }
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
            item { SettingsSectionTitle("说明") }
            item {
                SettingsCaption(
                    "在助手页对话时，内容会发送到你配置的模型服务商。只读查询与播放不依赖模型；" +
                        "写操作（播放/收藏/评分/歌单）会在对话中说明后执行，删除类操作会逐次请你批准。"
                )
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
