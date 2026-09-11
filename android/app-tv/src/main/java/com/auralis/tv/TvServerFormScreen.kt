// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.tv

import androidx.activity.compose.BackHandler
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Info
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusProperties
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp
import com.auralis.core.data.graph.AuralisGraph
import com.auralis.core.designsystem.LocalAuralisTheme
import com.auralis.core.designsystem.LocalReduceMotion
import com.auralis.core.designsystem.R as AuralisR
import com.auralis.core.domain.ServerAccount
import com.auralis.feature.server.R as ServerR
import com.auralis.feature.server.ServerFormState
import com.auralis.feature.server.ServerTestUi
import kotlinx.coroutines.launch
import kotlinx.coroutines.yield

/**
 * TV-specific server editor.
 *
 * Remote focus and text editing are separate states: moving onto a field only selects it; pressing
 * OK enters edit mode and opens the IME. Back exits the IME first and restores focus to the same
 * field. The last selected field is saveable, so an IME/window recreation never sends the remote
 * back to the first field.
 */
@Composable
fun TvServerFormScreen(
    graph: AuralisGraph,
    existing: ServerAccount?,
    onSuccess: () -> Unit,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = LocalAuralisTheme.current.colors
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    val keyboard = LocalSoftwareKeyboardController.current
    val fieldFocus = remember { List(5) { FocusRequester() } }
    var editingField by remember { mutableIntStateOf(-1) }
    var lastFocusedField by rememberSaveable { mutableIntStateOf(0) }
    val state = remember(graph, existing) {
        ServerFormState(
            context = context,
            scope = scope,
            graph = graph,
            existing = existing,
            onSuccess = { onSuccess() },
            onBack = onBack,
        )
    }

    fun leaveEditing() {
        val previous = editingField
        if (previous < 0) return
        lastFocusedField = previous
        editingField = -1
        keyboard?.hide()
        scope.launch {
            yield()
            runCatching { fieldFocus[previous].requestFocus() }
        }
    }

    BackHandler(enabled = !state.busy && !state.isTesting) {
        if (editingField >= 0) leaveEditing() else state.cancel()
    }
    LaunchedEffect(Unit) {
        yield()
        runCatching { fieldFocus[lastFocusedField.coerceIn(0, fieldFocus.lastIndex)].requestFocus() }
    }

    Column(
        modifier = modifier
            .fillMaxSize()
            .background(colors.background)
            .imePadding(),
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .height(82.dp)
                .padding(horizontal = 36.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            IconButton(
                onClick = { if (editingField >= 0) leaveEditing() else state.cancel() },
                enabled = !state.busy && !state.isTesting,
                modifier = Modifier.tvFocusVisual(RoundedCornerShape(50)),
            ) {
                Icon(
                    Icons.AutoMirrored.Filled.ArrowBack,
                    contentDescription = stringResource(AuralisR.string.back),
                    tint = colors.primaryText,
                )
            }
            Spacer(Modifier.width(18.dp))
            Text(
                text = stringResource(if (existing != null) ServerR.string.server_edit_title else AuralisR.string.add_server),
                style = MaterialTheme.typography.headlineMedium,
                fontWeight = FontWeight.SemiBold,
                color = colors.primaryText,
            )
        }
        HorizontalDivider(color = colors.separator)

        Box(Modifier.weight(1f).fillMaxWidth(), contentAlignment = Alignment.TopCenter) {
            Column(
                modifier = Modifier
                    .widthIn(max = 1120.dp)
                    .fillMaxWidth()
                    .verticalScroll(rememberScrollState())
                    .padding(horizontal = 48.dp, vertical = 30.dp),
                verticalArrangement = Arrangement.spacedBy(18.dp),
            ) {
                TvServerField(
                    value = state.displayName,
                    onValueChange = { state.displayName = it },
                    label = stringResource(ServerR.string.server_form_display_label),
                    enabled = !state.busy,
                    editing = editingField == 0,
                    containerFocus = fieldFocus[0],
                    onFocused = { lastFocusedField = 0 },
                    onBeginEditing = { lastFocusedField = 0; editingField = 0 },
                    onFinishEditing = ::leaveEditing,
                )
                TvServerField(
                    value = state.serverUrl,
                    onValueChange = { state.serverUrl = it },
                    label = stringResource(ServerR.string.server_form_url_label),
                    placeholder = "http://192.168.1.10:4533",
                    keyboardType = KeyboardType.Uri,
                    enabled = !state.busy,
                    editing = editingField == 1,
                    containerFocus = fieldFocus[1],
                    onFocused = { lastFocusedField = 1 },
                    onBeginEditing = { lastFocusedField = 1; editingField = 1 },
                    onFinishEditing = ::leaveEditing,
                )
                TvServerField(
                    value = state.username,
                    onValueChange = { state.username = it },
                    label = stringResource(ServerR.string.server_form_username_label),
                    keyboardType = KeyboardType.Ascii,
                    enabled = !state.busy,
                    editing = editingField == 2,
                    containerFocus = fieldFocus[2],
                    onFocused = { lastFocusedField = 2 },
                    onBeginEditing = { lastFocusedField = 2; editingField = 2 },
                    onFinishEditing = ::leaveEditing,
                )
                TvServerField(
                    value = state.password,
                    onValueChange = { state.password = it },
                    label = stringResource(
                        if (existing != null) ServerR.string.server_form_password_new_label
                        else ServerR.string.server_form_password_label,
                    ),
                    keyboardType = KeyboardType.Password,
                    password = true,
                    enabled = !state.busy,
                    editing = editingField == 3,
                    containerFocus = fieldFocus[3],
                    onFocused = { lastFocusedField = 3 },
                    onBeginEditing = { lastFocusedField = 3; editingField = 3 },
                    onFinishEditing = ::leaveEditing,
                )
                TvServerField(
                    value = state.externalUrl,
                    onValueChange = { state.externalUrl = it },
                    label = stringResource(ServerR.string.server_form_external_label),
                    placeholder = "https://music.example.com",
                    keyboardType = KeyboardType.Uri,
                    enabled = !state.busy,
                    editing = editingField == 4,
                    containerFocus = fieldFocus[4],
                    onFocused = { lastFocusedField = 4 },
                    onBeginEditing = { lastFocusedField = 4; editingField = 4 },
                    onFinishEditing = ::leaveEditing,
                )

                Text(
                    stringResource(ServerR.string.server_url_probe_note),
                    style = MaterialTheme.typography.bodyMedium,
                    color = colors.secondaryText,
                )
                state.localError?.let { message -> TvServerStatus(message = message, error = true) }
                if (state.busy && state.busyLabel != null) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        CircularProgressIndicator(modifier = Modifier.size(20.dp), strokeWidth = 2.dp, color = colors.accent)
                        Spacer(Modifier.width(10.dp))
                        Text(
                            stringResource(ServerR.string.server_busy_format, state.busyLabel!!),
                            color = colors.secondaryText,
                            style = MaterialTheme.typography.bodyMedium,
                        )
                    }
                }
                state.testUi?.let { result ->
                    when (result) {
                        ServerTestUi.Success -> TvServerStatus(stringResource(ServerR.string.server_test_ok), success = true)
                        ServerTestUi.AuthenticationFailed -> TvServerStatus(stringResource(ServerR.string.server_test_auth_failed), error = true)
                        ServerTestUi.Unreachable -> TvServerStatus(stringResource(ServerR.string.server_test_unreachable), error = true)
                        is ServerTestUi.Failed -> TvServerStatus(result.message, error = true)
                    }
                }
                state.failureMessage?.let { TvServerStatus(it, error = true) }
            }
        }

        HorizontalDivider(color = colors.separator)
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 48.dp, vertical = 20.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            OutlinedButton(
                onClick = { state.runTest() },
                enabled = !state.busy && !state.isTesting && editingField < 0,
                modifier = Modifier.tvFocusVisual(RoundedCornerShape(22.dp)),
            ) {
                if (state.isTesting) {
                    CircularProgressIndicator(modifier = Modifier.size(18.dp), strokeWidth = 2.dp, color = colors.accent)
                    Spacer(Modifier.width(10.dp))
                    Text(stringResource(ServerR.string.server_testing))
                } else {
                    Text(stringResource(AuralisR.string.test_connection))
                }
            }
            Spacer(Modifier.weight(1f))
            Button(
                onClick = { state.save() },
                enabled = state.canSave() && editingField < 0,
                modifier = Modifier.tvFocusVisual(RoundedCornerShape(22.dp)),
            ) {
                Text(stringResource(if (state.busy) ServerR.string.server_saving else AuralisR.string.save))
            }
        }
    }
}

@Composable
private fun TvServerField(
    value: String,
    onValueChange: (String) -> Unit,
    label: String,
    editing: Boolean,
    containerFocus: FocusRequester,
    onFocused: () -> Unit,
    onBeginEditing: () -> Unit,
    onFinishEditing: () -> Unit,
    placeholder: String? = null,
    keyboardType: KeyboardType = KeyboardType.Text,
    password: Boolean = false,
    enabled: Boolean = true,
) {
    val colors = LocalAuralisTheme.current.colors
    val reduceMotion = LocalReduceMotion.current
    val keyboard = LocalSoftwareKeyboardController.current
    val inputFocus = remember { FocusRequester() }
    val scale by animateFloatAsState(
        targetValue = if (editing) 1.018f else 1f,
        animationSpec = if (reduceMotion) androidx.compose.animation.core.snap() else androidx.compose.animation.core.tween(120),
        label = "tv-server-field-edit",
    )
    val shape = RoundedCornerShape(18.dp)

    LaunchedEffect(editing) {
        if (editing) {
            yield()
            if (runCatching { inputFocus.requestFocus() }.isSuccess) keyboard?.show()
        }
    }

    Box(
        modifier = Modifier
            .fillMaxWidth()
            .focusRequester(containerFocus)
            .onFocusChanged { if (it.hasFocus) onFocused() }
            .tvFocusableClick(shape = shape, enabled = enabled && !editing, onClick = onBeginEditing)
            .graphicsLayer {
                scaleX = scale
                scaleY = scale
            }
            .then(
                if (editing) Modifier.border(3.dp, colors.accent, shape)
                else Modifier,
            ),
    ) {
        OutlinedTextField(
            value = value,
            onValueChange = onValueChange,
            label = { Text(label) },
            placeholder = placeholder?.let { text -> { Text(text) } },
            singleLine = true,
            enabled = enabled,
            readOnly = !editing,
            visualTransformation = if (password) PasswordVisualTransformation() else VisualTransformation.None,
            keyboardOptions = KeyboardOptions(keyboardType = keyboardType, imeAction = ImeAction.Done),
            keyboardActions = KeyboardActions(onDone = { onFinishEditing() }),
            colors = OutlinedTextFieldDefaults.colors(
                focusedBorderColor = colors.accent,
                focusedLabelColor = colors.accent,
                cursorColor = colors.accent,
                unfocusedBorderColor = colors.separator.copy(alpha = 0.85f),
                focusedTextColor = colors.primaryText,
                unfocusedTextColor = colors.primaryText,
                disabledTextColor = colors.primaryText.copy(alpha = 0.55f),
            ),
            modifier = Modifier
                .fillMaxWidth()
                .height(74.dp)
                .focusRequester(inputFocus)
                .focusProperties { canFocus = editing },
            shape = shape,
        )
    }
}

@Composable
private fun TvServerStatus(
    message: String,
    success: Boolean = false,
    error: Boolean = false,
) {
    val colors = LocalAuralisTheme.current.colors
    val tint = when {
        success -> colors.success
        error -> colors.error
        else -> colors.secondaryText
    }
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(tint.copy(alpha = 0.08f), RoundedCornerShape(16.dp))
            .padding(14.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(
            if (success) Icons.Filled.CheckCircle else Icons.Filled.Info,
            contentDescription = null,
            tint = tint,
            modifier = Modifier.size(22.dp),
        )
        Spacer(Modifier.width(12.dp))
        Text(message, color = tint, style = MaterialTheme.typography.bodyMedium)
    }
}
