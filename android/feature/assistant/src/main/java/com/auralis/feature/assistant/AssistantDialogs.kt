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
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import com.auralis.core.designsystem.AuralisRadius
import com.auralis.core.designsystem.AuralisSpacing
import com.auralis.core.designsystem.LocalAuralisTheme
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/** 首次外发确认（对齐 Swift pendingConsent：允许一次 / 允许并记住 / 取消）。 */
@Composable
internal fun ConsentDialog(
    request: ConsentRequest,
    onAllowOnce: () -> Unit,
    onAllowAndRemember: () -> Unit,
    onCancel: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onCancel,
        title = { Text("允许发送以下内容到「${request.modelName}」？") },
        text = { Text(request.detail) },
        confirmButton = {
            TextButton(onClick = onAllowAndRemember) { Text("允许并记住") }
        },
        dismissButton = {
            Row {
                TextButton(onClick = onCancel) { Text("取消") }
                TextButton(onClick = onAllowOnce) { Text("允许一次") }
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
    AlertDialog(
        onDismissRequest = onReject,
        title = { Text(request.title) },
        text = { Text(request.detail) },
        confirmButton = {
            TextButton(onClick = onApprove) {
                Text(if (request.destructive) "批准并执行" else "执行", color = colors.error)
            }
        },
        dismissButton = {
            TextButton(onClick = onReject) { Text("取消") }
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

    Dialog(onDismissRequest = onDismiss) {
        Surface(
            shape = androidx.compose.foundation.shape.RoundedCornerShape(AuralisRadius.large),
            color = colors.elevated,
            modifier = Modifier.fillMaxWidth().heightIn(max = 640.dp),
        ) {
            Column(modifier = Modifier.padding(AuralisSpacing.medium)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text("会话", style = MaterialTheme.typography.titleLarge, color = colors.primaryText, modifier = Modifier.weight(1f))
                    TextButton(onClick = onOpenActionLog) { Text("操作日志") }
                    Spacer(Modifier.width(AuralisSpacing.small))
                    TextButton(onClick = onNew) { Text("新建") }
                }
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text("显示已归档", style = MaterialTheme.typography.bodyMedium, color = colors.secondaryText, modifier = Modifier.weight(1f))
                    Switch(checked = showArchived, onCheckedChange = { onToggleShowArchived() })
                }
                Spacer(Modifier.height(AuralisSpacing.medium))
                HorizontalDivider(color = colors.separator)
                if (sessions.isEmpty()) {
                    Text(
                        "还没有会话。点「新建」或直接在输入框提问。",
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
                                    Text(
                                        text = buildString {
                                            append(session.displayTitle)
                                            if (session.isPinned) append(" 📌")
                                        },
                                        style = MaterialTheme.typography.bodyLarge,
                                        color = colors.primaryText,
                                        maxLines = 1,
                                        modifier = Modifier.weight(1f).clickable { onSelect(session.id) },
                                    )
                                    TextButton(onClick = { onTogglePin(session.id) }) { Text(if (session.isPinned) "取消置顶" else "置顶") }
                                    TextButton(onClick = {
                                        renamingId = session.id
                                        renameText = session.title
                                    }) { Text("改名") }
                                    if (session.messages.isNotEmpty()) {
                                        TextButton(onClick = { onClearMessages(session.id) }) { Text("清空") }
                                    }
                                    TextButton(onClick = {
                                        confirmingDeleteId = session.id
                                    }) { Text("删除", color = colors.error) }
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
        androidx.compose.material3.AlertDialog(
            onDismissRequest = { renamingId = null },
            title = { Text("重命名会话") },
            text = {
                androidx.compose.material3.OutlinedTextField(
                    value = renameText,
                    onValueChange = { renameText = it },
                    singleLine = true,
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    onRename(id, renameText)
                    renamingId = null
                }) { Text("保存") }
            },
            dismissButton = {
                TextButton(onClick = { renamingId = null }) { Text("取消") }
            },
        )
    }

    confirmingDeleteId?.let { id ->
        val session = sessions.firstOrNull { it.id == id }
        androidx.compose.material3.AlertDialog(
            onDismissRequest = { confirmingDeleteId = null },
            title = { Text("删除会话？") },
            text = { Text("将永久删除「${session?.displayTitle ?: ""}」及其全部消息，此操作不可恢复。") },
            confirmButton = {
                TextButton(onClick = {
                    onDelete(id)
                    confirmingDeleteId = null
                }) { Text("删除", color = colors.error) }
            },
            dismissButton = {
                TextButton(onClick = { confirmingDeleteId = null }) { Text("取消") }
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
            shape = androidx.compose.foundation.shape.RoundedCornerShape(AuralisRadius.large),
            color = colors.elevated,
            modifier = Modifier.fillMaxWidth().heightIn(max = 560.dp),
        ) {
            Column(modifier = Modifier.padding(AuralisSpacing.medium)) {
                Text("操作日志", style = MaterialTheme.typography.titleLarge, color = colors.primaryText)
                Spacer(Modifier.height(AuralisSpacing.medium))
                HorizontalDivider(color = colors.separator)
                if (records.isEmpty()) {
                    Text(
                        "暂无记录。AI 执行写操作（播放/收藏/歌单等）后会记录在这里。",
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
                                    OutlinedButton(onClick = { onUndo(record) }) { Text("撤销") }
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
