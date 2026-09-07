package com.auralis.feature.server

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
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
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.Key
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import com.auralis.core.data.graph.AuralisGraph
import com.auralis.core.designsystem.LocalAuralisTheme
import com.auralis.core.designsystem.AuralisRadius
import com.auralis.core.designsystem.AuralisSpacing
import com.auralis.core.designsystem.R as AuralisR
import com.auralis.core.domain.ServerAccount
import kotlinx.coroutines.launch

// ---------------------------------------------------------------------------
// 服务器列表
// ---------------------------------------------------------------------------

/**
 * 服务器管理列表（对齐 macOS MacServerPage / 移动端设置页）：
 * 空状态引导添加；非空展示已保存服务器，点行切换、行内编辑/删除。
 */
@Composable
fun ServerListScreen(
    graph: AuralisGraph,
    onAdd: () -> Unit,
    onEdit: (ServerAccount) -> Unit,
    onEnter: () -> Unit,
    onBack: (() -> Unit)? = null,
    modifier: Modifier = Modifier,
) {
    val colors = LocalAuralisTheme.current.colors
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    val state = remember(graph) {
        ServerListState(context, scope, graph, onAdd, onEdit, onEnter)
    }
    androidx.compose.runtime.LaunchedEffect(graph) { state.load() }

    Column(
        modifier = modifier
            .fillMaxSize()
            .background(colors.background)
            .imePadding(),
    ) {
        HeaderRow(
            title = stringResource(R.string.server_title),
            onBack = onBack,
            action = {
                Button(onClick = { state.add() }) {
                    Icon(Icons.Filled.Add, contentDescription = null, modifier = Modifier.size(18.dp))
                    Spacer(Modifier.width(AuralisSpacing.small))
                    Text(stringResource(R.string.server_add_header_button))
                }
            },
        )
        HorizontalDivider(color = colors.separator)
        when {
            !state.loaded -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                CircularProgressIndicator(color = colors.accent)
            }

            state.servers.isEmpty() -> EmptyServers(state)
            else -> LazyColumn(Modifier.fillMaxSize()) {
                items(state.servers, key = { it.id.value }) { account ->
                    ServerRow(
                        account = account,
                        isActive = account.id.value == state.activeServerId,
                        routeLabel = state.routeLabel(account),
                        onClick = { state.switchTo(account) },
                        onEdit = { state.edit(account) },
                        onDelete = { state.requestDelete(account) },
                    )
                }
            }
        }
    }

    val deleteTarget = state.pendingDelete
    if (deleteTarget != null) {
        DeleteServerDialog(
            account = deleteTarget,
            onConfirm = { state.confirmDelete() },
            onDismiss = { state.dismissDelete() },
        )
    }
}

@Composable
private fun HeaderRow(
    title: String,
    onBack: (() -> Unit)? = null,
    action: @Composable () -> Unit,
) {
    val colors = LocalAuralisTheme.current.colors
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = AuralisSpacing.medium, vertical = AuralisSpacing.small),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (onBack != null) {
            IconButton(onClick = onBack) {
                Icon(
                    Icons.AutoMirrored.Filled.ArrowBack,
                    contentDescription = stringResource(AuralisR.string.back),
                    tint = colors.primaryText,
                )
            }
        }
        Text(
            title,
            style = MaterialTheme.typography.titleLarge,
            color = colors.primaryText,
            modifier = Modifier.weight(1f),
        )
        action()
    }
}

@Composable
private fun EmptyServers(state: ServerListState) {
    val colors = LocalAuralisTheme.current.colors
    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(AuralisSpacing.xLarge),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text(stringResource(R.string.server_empty_title), style = MaterialTheme.typography.titleMedium, color = colors.primaryText)
        Spacer(Modifier.height(AuralisSpacing.small))
        Text(
            stringResource(R.string.server_empty_desc_1),
            style = MaterialTheme.typography.bodyMedium,
            color = colors.secondaryText,
        )
        Spacer(Modifier.height(AuralisSpacing.medium))
        Text(
            stringResource(R.string.server_empty_desc_2),
            style = MaterialTheme.typography.bodyMedium,
            color = colors.secondaryText,
        )
        Spacer(Modifier.height(AuralisSpacing.xLarge))
        Button(onClick = { state.add() }) {
            Icon(Icons.Filled.Add, contentDescription = null, modifier = Modifier.size(18.dp))
            Spacer(Modifier.width(AuralisSpacing.small))
            Text(stringResource(AuralisR.string.add_server))
        }
    }
}

@Composable
private fun ServerRow(
    account: ServerAccount,
    isActive: Boolean,
    routeLabel: String?,
    onClick: () -> Unit,
    onEdit: () -> Unit,
    onDelete: () -> Unit,
) {
    val colors = LocalAuralisTheme.current.colors
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(start = AuralisSpacing.large, top = AuralisSpacing.medium, bottom = AuralisSpacing.medium),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Text(
                account.displayName,
                style = MaterialTheme.typography.bodyLarge,
                fontWeight = if (isActive) FontWeight.SemiBold else FontWeight.Normal,
                color = colors.primaryText,
                maxLines = 1,
            )
            Text(
                buildString {
                    append(maskedUrl(account.baseUrl))
                    if (routeLabel != null) append(" · $routeLabel")
                },
                style = MaterialTheme.typography.bodySmall,
                color = colors.secondaryText,
                maxLines = 1,
            )
        }
        if (isActive) {
            Spacer(Modifier.width(AuralisSpacing.small))
            Icon(
                Icons.Filled.CheckCircle,
                contentDescription = stringResource(R.string.server_active_icon),
                tint = colors.accent,
                modifier = Modifier.size(18.dp),
            )
        }
        IconButton(onClick = onEdit) {
            Icon(Icons.Filled.Edit, contentDescription = stringResource(R.string.server_edit_icon), tint = colors.secondaryText)
        }
        IconButton(onClick = onDelete) {
            Icon(Icons.Filled.Delete, contentDescription = stringResource(R.string.server_delete_icon), tint = colors.error)
        }
    }
    HorizontalDivider(color = colors.separator)
}

@Composable
private fun DeleteServerDialog(
    account: ServerAccount,
    onConfirm: () -> Unit,
    onDismiss: () -> Unit,
) {
    val colors = LocalAuralisTheme.current.colors
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.server_delete_title), color = colors.primaryText) },
        text = {
            Text(
                stringResource(R.string.server_delete_message),
                color = colors.secondaryText,
            )
        },
        confirmButton = {
            TextButton(onClick = onConfirm) {
                Text(stringResource(AuralisR.string.delete), color = colors.error, fontWeight = FontWeight.SemiBold)
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text(stringResource(AuralisR.string.cancel), color = colors.primaryText) }
        },
        containerColor = colors.surface,
    )
}

// ---------------------------------------------------------------------------
// 服务器表单（添加 / 编辑）
// ---------------------------------------------------------------------------

/** 表单可用作整页（添加/编辑共用）。标题区分两种模式。 */
@Composable
fun ServerFormScreen(
    graph: AuralisGraph,
    existing: ServerAccount?,
    onSuccess: () -> Unit,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = LocalAuralisTheme.current.colors
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
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

    Column(
        modifier = modifier
            .fillMaxSize()
            .background(colors.background)
            .imePadding(),
    ) {
        HeaderRow(
            title = stringResource(if (existing != null) R.string.server_edit_title else AuralisR.string.add_server),
            action = {
                TextButton(onClick = { state.cancel() }, enabled = !state.busy && !state.isTesting) {
                    Text(stringResource(AuralisR.string.cancel), color = colors.secondaryText)
                }
            },
        )
        HorizontalDivider(color = colors.separator)

        Column(
            modifier = Modifier
                .weight(1f)
                .verticalScroll(rememberScrollState())
                .padding(horizontal = AuralisSpacing.large, vertical = AuralisSpacing.large),
            verticalArrangement = Arrangement.spacedBy(AuralisSpacing.medium),
        ) {
            OutlinedTextField(
                value = state.displayName,
                onValueChange = { state.displayName = it },
                label = { Text(stringResource(R.string.server_form_display_label)) },
                singleLine = true,
                enabled = !state.busy,
                modifier = Modifier.fillMaxWidth(),
            )
            OutlinedTextField(
                value = state.serverUrl,
                onValueChange = { state.serverUrl = it },
                label = { Text(stringResource(R.string.server_form_url_label)) },
                placeholder = { Text("http://192.168.1.10:4533") },
                singleLine = true,
                enabled = !state.busy,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri),
                modifier = Modifier.fillMaxWidth(),
            )
            OutlinedTextField(
                value = state.username,
                onValueChange = { state.username = it },
                label = { Text(stringResource(R.string.server_form_username_label)) },
                singleLine = true,
                enabled = !state.busy,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Ascii),
                modifier = Modifier.fillMaxWidth(),
            )
            OutlinedTextField(
                value = state.password,
                onValueChange = { state.password = it },
                label = {
                    Text(
                        stringResource(
                            if (existing != null) R.string.server_form_password_new_label
                            else R.string.server_form_password_label,
                        )
                    )
                },
                singleLine = true,
                enabled = !state.busy,
                visualTransformation = PasswordVisualTransformation(),
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password),
                modifier = Modifier.fillMaxWidth(),
            )
            OutlinedTextField(
                value = state.externalUrl,
                onValueChange = { state.externalUrl = it },
                label = { Text(stringResource(R.string.server_form_external_label)) },
                placeholder = { Text("https://music.example.com") },
                singleLine = true,
                enabled = !state.busy,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri),
                modifier = Modifier.fillMaxWidth(),
            )

            Text(
                stringResource(R.string.server_url_probe_note),
                style = MaterialTheme.typography.bodySmall,
                color = colors.secondaryText,
            )
            if (existing != null) {
                Text(
                    stringResource(R.string.server_edit_url_note),
                    style = MaterialTheme.typography.bodySmall,
                    color = colors.secondaryText,
                )
            }

            // 连接安全提示（对齐 iOS「连接安全」区）。
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Filled.Key, contentDescription = null, tint = colors.secondaryText, modifier = Modifier.size(14.dp))
                Spacer(Modifier.width(AuralisSpacing.small))
                Text(stringResource(R.string.server_security_keystore), style = MaterialTheme.typography.bodySmall, color = colors.secondaryText)
            }
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Filled.Lock, contentDescription = null, tint = colors.secondaryText, modifier = Modifier.size(14.dp))
                Spacer(Modifier.width(AuralisSpacing.small))
                Text(stringResource(R.string.server_security_https), style = MaterialTheme.typography.bodySmall, color = colors.secondaryText)
            }

            // 本地校验错误：仅在无测试结果时展示。
            state.localError?.let { error ->
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Filled.Info, contentDescription = null, tint = colors.error, modifier = Modifier.size(14.dp))
                    Spacer(Modifier.width(AuralisSpacing.small))
                    Text(error, style = MaterialTheme.typography.bodySmall, color = colors.error)
                }
            }

            // 连接进度：正在「检查地址」…（跟随 core stage）。
            if (state.busy && state.busyLabel != null) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    CircularProgressIndicator(
                        modifier = Modifier.size(14.dp),
                        strokeWidth = 2.dp,
                        color = colors.accent,
                    )
                    Spacer(Modifier.width(AuralisSpacing.small))
                    Text(
                        stringResource(R.string.server_busy_format, state.busyLabel!!),
                        style = MaterialTheme.typography.bodySmall,
                        color = colors.secondaryText,
                    )
                }
            }

            // 测试连接结果行。
            state.testUi?.let { status ->
                Row(verticalAlignment = Alignment.CenterVertically) {
                    when (status) {
                        ServerTestUi.Success -> {
                            Icon(Icons.Filled.CheckCircle, contentDescription = null, tint = colors.success, modifier = Modifier.size(14.dp))
                            Spacer(Modifier.width(AuralisSpacing.small))
                            Text(stringResource(R.string.server_test_ok), style = MaterialTheme.typography.bodySmall, color = colors.success)
                        }

                        ServerTestUi.AuthenticationFailed -> {
                            Icon(Icons.Filled.Info, contentDescription = null, tint = colors.error, modifier = Modifier.size(14.dp))
                            Spacer(Modifier.width(AuralisSpacing.small))
                            Text(stringResource(R.string.server_test_auth_failed), style = MaterialTheme.typography.bodySmall, color = colors.error)
                        }

                        ServerTestUi.Unreachable -> {
                            Icon(Icons.Filled.Info, contentDescription = null, tint = colors.warning, modifier = Modifier.size(14.dp))
                            Spacer(Modifier.width(AuralisSpacing.small))
                            Text(stringResource(R.string.server_test_unreachable), style = MaterialTheme.typography.bodySmall, color = colors.warning)
                        }

                        is ServerTestUi.Failed -> {
                            Icon(Icons.Filled.Info, contentDescription = null, tint = colors.error, modifier = Modifier.size(14.dp))
                            Spacer(Modifier.width(AuralisSpacing.small))
                            Text(status.message, style = MaterialTheme.typography.bodySmall, color = colors.error)
                        }
                    }
                }
            }

            // 保存失败（连接失败）：可折叠详情。
            state.failureMessage?.let { message ->
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .background(colors.error.copy(alpha = 0.08f))
                        .padding(AuralisSpacing.medium),
                    verticalArrangement = Arrangement.spacedBy(AuralisSpacing.xSmall),
                ) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(stringResource(R.string.server_failed_title), style = MaterialTheme.typography.bodyMedium, color = colors.error, fontWeight = FontWeight.SemiBold)
                        Spacer(Modifier.weight(1f))
                        TextButton(onClick = { state.showErrorDetails = !state.showErrorDetails }) {
                            Text(
                                stringResource(if (state.showErrorDetails) R.string.server_details_collapse else R.string.server_details_expand),
                                color = colors.error,
                            )
                        }
                    }
                    val shown = if (state.showErrorDetails) message else message.take(60) + if (message.length > 60) "…" else ""
                    Text(shown, style = MaterialTheme.typography.bodySmall, color = colors.secondaryText)
                }
            }
        }

        HorizontalDivider(color = colors.separator)
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = AuralisSpacing.large, vertical = AuralisSpacing.medium),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            OutlinedButton(
                onClick = { state.runTest() },
                enabled = !state.busy && !state.isTesting,
            ) {
                if (state.isTesting) {
                    CircularProgressIndicator(modifier = Modifier.size(14.dp), strokeWidth = 2.dp, color = colors.accent)
                    Spacer(Modifier.width(AuralisSpacing.small))
                    Text(stringResource(R.string.server_testing))
                } else {
                    Text(stringResource(R.string.server_test_action))
                }
            }
            Spacer(Modifier.weight(1f))
            Button(
                onClick = { state.save() },
                enabled = state.canSave(),
            ) {
                Text(stringResource(if (state.busy) R.string.server_saving else R.string.server_save))
            }
        }
    }
}
