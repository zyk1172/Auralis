// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.feature.assistant

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import com.auralis.core.designsystem.AuralisRadius
import com.auralis.core.designsystem.AuralisSpacing
import com.auralis.core.designsystem.LocalAuralisTheme
import com.auralis.core.designsystem.R as AuralisR
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import kotlinx.coroutines.yield

/** 首次外发确认（对齐 Swift pendingConsent：允许一次 / 允许并记住 / 取消）。 */
@Composable
internal fun ConsentDialog(
    request: ConsentRequest,
    onAllowOnce: () -> Unit,
    onAllowAndRemember: () -> Unit,
    onCancel: () -> Unit,
) {
    val buttonShape = RoundedCornerShape(10.dp)
    AlertDialog(
        onDismissRequest = onCancel,
        title = { Text(stringResource(R.string.assistant_consent_title, request.modelName)) },
        text = { Text(request.detail) },
        confirmButton = {
            TextButton(
                onClick = onAllowAndRemember,
                modifier = Modifier.assistantTvFocus(buttonShape),
            ) { Text(stringResource(R.string.assistant_allow_and_remember)) }
        },
        dismissButton = {
            Row {
                TextButton(
                    onClick = onCancel,
                    modifier = Modifier.assistantTvFocus(buttonShape),
                ) { Text(stringResource(AuralisR.string.cancel)) }
                TextButton(
                    onClick = onAllowOnce,
                    modifier = Modifier.assistantTvFocus(buttonShape),
                ) { Text(stringResource(R.string.assistant_allow_once)) }
            }
        },
    )
}

/** 副作用/破坏性操作确认（对齐 Swift pendingOperationConfirmation：批准并执行 / 取消）。 */
@Composable
internal fun OperationConfirmDialog(
    request: OperationConfirmRequest,
    onApprove: () -> Unit,
    onReject: () -> Unit,
) {
    val colors = LocalAuralisTheme.current.colors
    val buttonShape = RoundedCornerShape(10.dp)
    AlertDialog(
        onDismissRequest = onReject,
        title = { Text(request.title) },
        text = { Text(request.detail) },
        confirmButton = {
            TextButton(
                onClick = onApprove,
                modifier = Modifier.assistantTvFocus(buttonShape),
            ) {
                Text(
                    if (request.destructive) stringResource(R.string.assistant_approve_and_run) else stringResource(R.string.assistant_execute),
                    color = colors.error,
                )
            }
        },
        dismissButton = {
            TextButton(
                onClick = onReject,
                modifier = Modifier.assistantTvFocus(buttonShape),
            ) { Text(stringResource(AuralisR.string.cancel)) }
        },
    )
}

/** 会话列表（对齐 Swift .sessions sheet：新建/置顶/改名/清空/归档/删除）。 */
@Composable
internal fun SessionsDialog(
    sessions: List<AssistantSession>,
    showArchived: Boolean,
    onToggleShowArchived: () -> Unit,
    onNew: () -> Unit,
    onSelect: (String) -> Unit,
    onRename: (String, String) -> Unit,
    onTogglePin: (String) -> Unit,
    onToggleArchived: (String) -> Unit,
    onClearMessages: (String) -> Unit,
    onDelete: (String) -> Unit,
    onOpenActionLog: () -> Unit,
    onDismiss: () -> Unit,
) {
    val colors = LocalAuralisTheme.current.colors
    var renamingId by remember { mutableStateOf<String?>(null) }
    var renameText by remember { mutableStateOf("") }
    var confirmingDeleteId by remember { mutableStateOf<String?>(null) }
    val initialFocus = remember { FocusRequester() }
    val buttonShape = RoundedCornerShape(10.dp)

    LaunchedEffect(Unit) {
        if (assistantIsTelevision()) {
            yield()
            runCatching { initialFocus.requestFocus() }
        }
    }

    Dialog(onDismissRequest = onDismiss) {
        Surface(
            shape = RoundedCornerShape(AuralisRadius.large),
            color = colors.elevated,
            modifier = Modifier.fillMaxWidth().heightIn(max = 640.dp),
        ) {
            Column(modifier = Modifier.padding(AuralisSpacing.medium)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        stringResource(R.string.assistant_sessions),
                        style = MaterialTheme.typography.titleLarge,
                        color = colors.primaryText,
                        modifier = Modifier.weight(1f),
                    )
                    TextButton(
                        onClick = onOpenActionLog,
                        modifier = Modifier
                            .focusRequester(initialFocus)
                            .assistantTvFocus(buttonShape),
                    ) { Text(stringResource(R.string.assistant_action_log)) }
                    Spacer(Modifier.width(AuralisSpacing.small))
                    TextButton(
                        onClick = onNew,
                        modifier = Modifier.assistantTvFocus(buttonShape),
                    ) { Text(stringResource(R.string.assistant_new)) }
                }
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        stringResource(R.string.assistant_show_archived),
                        style = MaterialTheme.typography.bodyMedium,
                        color = colors.secondaryText,
                        modifier = Modifier.weight(1f),
                    )
                    Switch(
                        checked = showArchived,
                        onCheckedChange = { onToggleShowArchived() },
                        modifier = Modifier.assistantTvFocus(RoundedCornerShape(18.dp)),
                    )
                }
                Spacer(Modifier.height(AuralisSpacing.medium))
                HorizontalDivider(color = colors.separator)
                if (sessions.isEmpty()) {
                    Text(
                        stringResource(R.string.assistant_no_sessions_yet),
                        style = MaterialTheme.typography.bodyMedium,
                        color = colors.secondaryText,
                        modifier = Modifier.padding(vertical = AuralisSpacing.large),
                    )
                } else {
                    LazyColumn(modifier = Modifier.weight(1f, fill = true)) {
                        items(sessions, key = { it.id }) { session ->
                            Column(modifier = Modifier.fillMaxWidth()) {
                                Row(
                                    verticalAlignment = Alignment.CenterVertically,
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .padding(vertical = AuralisSpacing.small),
                                ) {
                                    val sessionTitle = session.title.ifBlank { stringResource(R.string.assistant_new_session) }
                                    Text(
                                        text = if (session.isPinned) "$sessionTitle 📌" else sessionTitle,
                                        style = MaterialTheme.typography.bodyLarge,
                                        color = colors.primaryText,
                                        maxLines = 1,
                                        modifier = Modifier
                                            .weight(1f)
                                            .assistantTvFocus(buttonShape)
                                            .clickable { onSelect(session.id) }
                                            .padding(horizontal = 10.dp, vertical = 8.dp),
                                    )
                                    TextButton(
                                        onClick = { onTogglePin(session.id) },
                                        modifier = Modifier.assistantTvFocus(buttonShape),
                                    ) { Text(if (session.isPinned) stringResource(R.string.assistant_unpin) else stringResource(R.string.assistant_pin)) }
                                    TextButton(
                                        onClick = {
                                            renamingId = session.id
                                            renameText = session.title
                                        },
                                        modifier = Modifier.assistantTvFocus(buttonShape),
                                    ) { Text(stringResource(R.string.assistant_rename)) }
                                    if (session.messages.isNotEmpty()) {
                                        TextButton(
                                            onClick = { onClearMessages(session.id) },
                                            modifier = Modifier.assistantTvFocus(buttonShape),
                                        ) { Text(stringResource(R.string.assistant_clear)) }
                                    }
                                    TextButton(
                                        onClick = { confirmingDeleteId = session.id },
                                        modifier = Modifier.assistantTvFocus(buttonShape),
                                    ) { Text(stringResource(AuralisR.string.delete), color = colors.error) }
                                }
                                HorizontalDivider(color = colors.separator.copy(alpha = 0.5f))
                            }
                        }
                    }
                }
            }
        }
    }

    renamingId?.let { id ->
        AlertDialog(
            onDismissRequest = { renamingId = null },
            title = { Text(stringResource(R.string.assistant_rename_session)) },
            text = {
                androidx.compose.material3.OutlinedTextField(
                    value = renameText,
                    onValueChange = { renameText = it },
                    singleLine = true,
                )
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        onRename(id, renameText)
                        renamingId = null
                    },
                    modifier = Modifier.assistantTvFocus(buttonShape),
                ) { Text(stringResource(AuralisR.string.save)) }
            },
            dismissButton = {
                TextButton(
                    onClick = { renamingId = null },
                    modifier = Modifier.assistantTvFocus(buttonShape),
                ) { Text(stringResource(AuralisR.string.cancel)) }
            },
        )
    }

    confirmingDeleteId?.let { id ->
        val session = sessions.firstOrNull { it.id == id }
        AlertDialog(
            onDismissRequest = { confirmingDeleteId = null },
            title = { Text(stringResource(R.string.assistant_delete_session)) },
            text = {
                val titleText = session?.title?.ifBlank { stringResource(R.string.assistant_new_session) } ?: ""
                Text(stringResource(R.string.assistant_delete_session_body, titleText))
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        onDelete(id)
                        confirmingDeleteId = null
                    },
                    modifier = Modifier.assistantTvFocus(buttonShape),
                ) { Text(stringResource(AuralisR.string.delete), color = colors.error) }
            },
            dismissButton = {
                TextButton(
                    onClick = { confirmingDeleteId = null },
                    modifier = Modifier.assistantTvFocus(buttonShape),
                ) { Text(stringResource(AuralisR.string.cancel)) }
            },
        )
    }
}

/** 操作日志（对齐 agent.actionRecords；可逆项可真实撤销）。 */
@Composable
internal fun ActionLogDialog(
    records: List<AssistantActionRecord>,
    onUndo: (AssistantActionRecord) -> Unit,
    onDismiss: () -> Unit,
) {
    val colors = LocalAuralisTheme.current.colors
    Dialog(onDismissRequest = onDismiss) {
        Surface(
            shape = RoundedCornerShape(AuralisRadius.large),
            color = colors.elevated,
            modifier = Modifier.fillMaxWidth().heightIn(max = 560.dp),
        ) {
            Column(modifier = Modifier.padding(AuralisSpacing.medium)) {
                Text(stringResource(R.string.assistant_action_log), style = MaterialTheme.typography.titleLarge, color = colors.primaryText)
                Spacer(Modifier.height(AuralisSpacing.medium))
                HorizontalDivider(color = colors.separator)
                if (records.isEmpty()) {
                    Text(
                        stringResource(R.string.assistant_action_log_empty),
                        style = MaterialTheme.typography.bodyMedium,
                        color = colors.secondaryText,
                        modifier = Modifier.padding(vertical = AuralisSpacing.large),
                    )
                } else {
                    LazyColumn(modifier = Modifier.weight(1f, fill = true)) {
                        items(records, key = { it.id }) { record ->
                            Row(
                                verticalAlignment = Alignment.CenterVertically,
                                modifier = Modifier.fillMaxWidth().padding(vertical = AuralisSpacing.small),
                            ) {
                                Column(modifier = Modifier.weight(1f)) {
                                    Text(record.summary, style = MaterialTheme.typography.bodyLarge, color = colors.primaryText)
                                    Text(
                                        logTime(record.createdAtMillis),
                                        style = MaterialTheme.typography.labelSmall,
                                        color = colors.secondaryText,
                                    )
                                }
                                if (record.isReversible) {
                                    OutlinedButton(
                                        onClick = { onUndo(record) },
                                        modifier = Modifier.assistantTvFocus(RoundedCornerShape(10.dp)),
                                    ) { Text(stringResource(R.string.assistant_undo)) }
                                }
                            }
                            HorizontalDivider(color = colors.separator.copy(alpha = 0.5f))
                        }
                    }
                }
            }
        }
    }
}

private fun logTime(millis: Long): String =
    runCatching { SimpleDateFormat("MM-dd HH:mm:ss", Locale.getDefault()).format(Date(millis)) }.getOrDefault("")
