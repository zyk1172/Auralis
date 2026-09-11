// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.feature.settings

import android.content.res.Configuration
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.text.KeyboardActions
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
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusProperties
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp
import com.auralis.core.ai.AiProviderConfiguration
import com.auralis.core.ai.AiProviderFactory
import com.auralis.core.ai.AiProviderFailureKind
import com.auralis.core.ai.AiProviderException
import com.auralis.core.data.graph.AuralisGraph
import com.auralis.core.data.prefs.AiConnectionSettings
import com.auralis.core.designsystem.AuralisSpacing
import com.auralis.core.designsystem.LocalAuralisTheme
import com.auralis.core.designsystem.R as AuralisR
import kotlinx.coroutines.launch
import kotlinx.coroutines.yield

/**
 * AI 助手设置页（对齐 Swift `AIProviderSettingsPage`）。
 *
 * TV keeps the same data model and provider behavior, but text fields use a two-stage interaction:
 * D-pad focus only selects a field; OK explicitly enters edit mode and opens the IME. Mobile keeps
 * the ordinary touch/text-field behavior.
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
    val isTelevision = remember(context) {
        (context.resources.configuration.uiMode and Configuration.UI_MODE_TYPE_MASK) ==
            Configuration.UI_MODE_TYPE_TELEVISION
    }

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
    var testState by remember { mutableStateOf<Pair<String, Boolean>?>(null) }

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
            prefs.setAiMaxContextTokens(
                maxContext.toIntOrNull() ?: AiConnectionSettings.DEFAULT_MAX_CONTEXT_TOKENS,
            )
            prefs.setAiMaxOutputTokens(
                maxOutput.toIntOrNull() ?: AiConnectionSettings.DEFAULT_MAX_OUTPUT_TOKENS,
            )
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
                    name = context.getString(R.string.settings_ai_auto_protocol),
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
                val provider = AiProviderFactory.create(config, apiKeyProvider = { apiKey })
                provider.testConnection()
            }.onSuccess { result ->
                val diagnostic = result.diagnostics?.let {
                    context.getString(
                        R.string.settings_ai_diagnostics_format,
                        it.streaming.name,
                        it.nativeTools.name,
                    )
                } ?: ""
                testState = context.getString(
                    R.string.settings_ai_connect_success,
                    result.model,
                    result.latencyMillis,
                    diagnostic,
                ).trim() to true
            }.onFailure { e ->
                val reason = when (e) {
                    is AiProviderException -> when (e.kind) {
                        AiProviderFailureKind.Authentication -> context.getString(R.string.settings_ai_error_auth)
                        AiProviderFailureKind.ModelRouting,
                        AiProviderFailureKind.UpstreamRouting,
                        -> context.getString(R.string.settings_ai_error_routing)
                        AiProviderFailureKind.RateLimited -> context.getString(R.string.settings_ai_error_rate_limited)
                        AiProviderFailureKind.IncompatibleRequest ->
                            context.getString(R.string.settings_ai_error_incompatible, e.message)
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
            item {
                SettingsDetailTopBar(
                    title = stringResource(R.string.settings_ai_title),
                    onBack = onBack,
                )
            }
            item {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(vertical = AuralisSpacing.small),
                ) {
                    Column(modifier = Modifier.weight(1f)) {
                        Text(
                            stringResource(R.string.settings_ai_enable),
                            style = MaterialTheme.typography.bodyLarge,
                            color = colors.primaryText,
                        )
                        Text(
                            stringResource(
                                if (consentGiven) {
                                    R.string.settings_ai_consent_granted_subtitle
                                } else {
                                    R.string.settings_ai_consent_pending_subtitle
                                },
                            ),
                            style = MaterialTheme.typography.bodySmall,
                            color = colors.secondaryText,
                        )
                    }
                    Switch(
                        checked = enabled,
                        onCheckedChange = {
                            enabled = it
                            savedNotice = null
                        },
                    )
                }
            }

            item { SettingsSectionTitle(stringResource(R.string.settings_ai_api_section)) }
            item { FieldLabel(stringResource(R.string.settings_ai_base_url_label)) }
            item {
                AiSettingsTextField(
                    value = baseUrl,
                    onValueChange = { baseUrl = it; savedNotice = null },
                    television = isTelevision,
                    keyboardType = KeyboardType.Uri,
                )
            }
            item { FieldLabel(stringResource(R.string.settings_ai_api_path_label)) }
            item {
                AiSettingsTextField(
                    value = apiPath,
                    onValueChange = { apiPath = it; savedNotice = null },
                    television = isTelevision,
                )
            }
            item { SettingsCaption(stringResource(R.string.settings_ai_api_path_hint)) }
            item { FieldLabel(stringResource(R.string.settings_ai_model_label)) }
            item {
                AiSettingsTextField(
                    value = model,
                    onValueChange = { model = it; savedNotice = null },
                    television = isTelevision,
                )
            }
            item { FieldLabel("API Key") }
            item {
                AiSettingsTextField(
                    value = apiKeyInput,
                    onValueChange = { apiKeyInput = it; savedNotice = null },
                    television = isTelevision,
                    visualTransformation = PasswordVisualTransformation(),
                    placeholder = stringResource(
                        if (apiKeySaved) {
                            R.string.settings_ai_key_placeholder_saved
                        } else {
                            R.string.settings_ai_key_placeholder_new
                        },
                    ),
                )
            }
            item { SettingsCaption(stringResource(R.string.settings_ai_key_caption)) }

            item { SettingsSectionTitle(stringResource(R.string.settings_ai_advanced_section)) }
            item { FieldLabel(stringResource(R.string.settings_ai_context_label)) }
            item {
                AiSettingsTextField(
                    value = maxContext,
                    onValueChange = {
                        maxContext = it.filter(Char::isDigit)
                        savedNotice = null
                    },
                    television = isTelevision,
                    keyboardType = KeyboardType.Number,
                )
            }
            item { FieldLabel(stringResource(R.string.settings_ai_output_label)) }
            item {
                AiSettingsTextField(
                    value = maxOutput,
                    onValueChange = {
                        maxOutput = it.filter(Char::isDigit)
                        savedNotice = null
                    },
                    television = isTelevision,
                    keyboardType = KeyboardType.Number,
                )
            }

            item {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(vertical = AuralisSpacing.small),
                ) {
                    Column(modifier = Modifier.weight(1f)) {
                        Text(
                            stringResource(R.string.settings_ai_tool_title),
                            style = MaterialTheme.typography.bodyLarge,
                            color = colors.primaryText,
                        )
                        Text(
                            stringResource(R.string.settings_ai_tool_note),
                            style = MaterialTheme.typography.bodySmall,
                            color = colors.secondaryText,
                        )
                    }
                    Switch(
                        checked = toolCalling,
                        onCheckedChange = {
                            toolCalling = it
                            savedNotice = null
                        },
                    )
                }
            }
            item {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(vertical = AuralisSpacing.small),
                ) {
                    Column(modifier = Modifier.weight(1f)) {
                        Text(
                            stringResource(R.string.settings_ai_consent_title),
                            style = MaterialTheme.typography.bodyLarge,
                            color = colors.primaryText,
                        )
                        Text(
                            stringResource(
                                if (consentGiven) {
                                    R.string.settings_ai_consent_granted_note
                                } else {
                                    R.string.settings_ai_consent_pending_note
                                },
                            ),
                            style = MaterialTheme.typography.bodySmall,
                            color = colors.secondaryText,
                        )
                    }
                    if (consentGiven) {
                        TextButton(
                            onClick = {
                                scope.launch {
                                    graph.preferences.setAiConsentGiven(false)
                                    consentGiven = false
                                    savedNotice = context.getString(
                                        R.string.settings_ai_consent_revoked_notice,
                                    )
                                }
                            },
                        ) {
                            Text(stringResource(R.string.settings_ai_revoke))
                        }
                    }
                }
            }
            item {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(vertical = AuralisSpacing.small),
                ) {
                    Button(onClick = ::save, modifier = Modifier.weight(1f)) {
                        Text(stringResource(AuralisR.string.save))
                    }
                    Spacer(Modifier.width(AuralisSpacing.medium))
                    OutlinedButton(
                        onClick = ::testConnection,
                        enabled = currentSettings().isComplete,
                        modifier = Modifier.weight(1f),
                    ) {
                        Text(stringResource(AuralisR.string.test_connection))
                    }
                }
            }
            savedNotice?.let { notice ->
                item {
                    Text(
                        notice,
                        style = MaterialTheme.typography.bodyMedium,
                        color = colors.success,
                    )
                }
            }
            testState?.let { (text, success) ->
                item {
                    Text(
                        text,
                        style = MaterialTheme.typography.bodyMedium,
                        color = if (success) colors.success else colors.error,
                    )
                }
            }
            item { SettingsSectionTitle(stringResource(R.string.settings_ai_about_section)) }
            item { SettingsCaption(stringResource(R.string.settings_ai_privacy_note)) }
            item { Spacer(Modifier.height(AuralisSpacing.large)) }
        }
    }
}

/**
 * Text field that keeps mobile behavior intact while separating TV navigation focus from editing.
 * The outer clickable receives the app-level TV focus indication. The real text editor cannot take
 * focus until the user presses OK, so simply moving through the page never summons the IME.
 */
@Composable
private fun AiSettingsTextField(
    value: String,
    onValueChange: (String) -> Unit,
    television: Boolean,
    keyboardType: KeyboardType = KeyboardType.Text,
    visualTransformation: VisualTransformation = VisualTransformation.None,
    placeholder: String? = null,
) {
    if (!television) {
        OutlinedTextField(
            value = value,
            onValueChange = onValueChange,
            singleLine = true,
            keyboardOptions = KeyboardOptions(keyboardType = keyboardType),
            visualTransformation = visualTransformation,
            placeholder = placeholder?.let { text -> { Text(text) } },
            modifier = Modifier.fillMaxWidth(),
        )
        return
    }

    val keyboard = LocalSoftwareKeyboardController.current
    val scope = rememberCoroutineScope()
    val selectorFocus = remember { FocusRequester() }
    val editorFocus = remember { FocusRequester() }
    var editing by remember { mutableStateOf(false) }

    fun finishEditing() {
        if (!editing) return
        editing = false
        keyboard?.hide()
        scope.launch {
            yield()
            runCatching { selectorFocus.requestFocus() }
        }
    }

    BackHandler(enabled = editing) { finishEditing() }

    LaunchedEffect(editing) {
        if (editing) {
            yield()
            if (runCatching { editorFocus.requestFocus() }.isSuccess) {
                keyboard?.show()
            }
        }
    }

    Box(
        modifier = Modifier
            .fillMaxWidth()
            .focusRequester(selectorFocus)
            .clickable(enabled = !editing) { editing = true },
    ) {
        OutlinedTextField(
            value = value,
            onValueChange = onValueChange,
            singleLine = true,
            readOnly = !editing,
            keyboardOptions = KeyboardOptions(
                keyboardType = keyboardType,
                imeAction = ImeAction.Done,
            ),
            keyboardActions = KeyboardActions(onDone = { finishEditing() }),
            visualTransformation = visualTransformation,
            placeholder = placeholder?.let { text -> { Text(text) } },
            modifier = Modifier
                .fillMaxWidth()
                .focusRequester(editorFocus)
                .focusProperties { canFocus = editing },
        )
    }
}

@Composable
private fun FieldLabel(text: String) {
    val colors = LocalAuralisTheme.current.colors
    Text(
        text,
        style = MaterialTheme.typography.labelLarge,
        color = colors.secondaryText,
        modifier = Modifier.padding(
            top = AuralisSpacing.small,
            bottom = AuralisSpacing.xSmall,
        ),
    )
}
