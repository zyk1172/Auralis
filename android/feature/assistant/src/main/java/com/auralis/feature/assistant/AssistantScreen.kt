// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.feature.assistant

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.List
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.auralis.core.designsystem.AuralisSpacing
import com.auralis.core.designsystem.LocalAuralisTheme
import com.auralis.core.designsystem.R as AuralisR

/**
 * AI 助手页（对齐 Swift `AssistantView`）。
 *
 * - Header：左状态标签（live = 绿勾+模型；否则黄三角「未配置模型接口」+ 配置入口），
 *   右侧：搜索音乐库（S6 兜底能力）、会话列表；
 * - 消息流：用户气泡右对齐 / 助手气泡左对齐 + 复制；运行中插入瞬态工具状态行；
 * - 输入区：发送/停止随运行切换；AI 未配置时如实禁用发送并引导配置；
 * - AI 失败/未授权如实红字呈现，绝不伪装本地模式。
 */
@Composable
fun AssistantScreen(
    coordinator: AssistantCoordinator,
    onOpenSearch: () -> Unit,
    onOpenAiSettings: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = LocalAuralisTheme.current.colors

    val aiStatus by coordinator.aiStatus.collectAsState()
    val activeMessages by coordinator.activeMessages.collectAsState()
    val run by coordinator.run.collectAsState()
    val lastError by coordinator.lastError.collectAsState()
    val consent by coordinator.consent.collectAsState()
    val confirm by coordinator.confirm.collectAsState()
    val showArchived by coordinator.showArchived.collectAsState()
    val sessions by coordinator.sessions.collectAsState()
    val actions by coordinator.actions.collectAsState()

    val visibleSessions = remember(sessions, showArchived) {
        sessions
            .filter { showArchived || !it.isArchived }
            .sortedWith(compareByDescending<AssistantSession> { it.isPinned }.thenByDescending { it.updatedAtMillis })
    }

    var draft by rememberSaveable { mutableStateOf("") }
    var sessionsOpen by remember { mutableStateOf(false) }
    var actionLogOpen by remember { mutableStateOf(false) }
    val listState = rememberLazyListState()

    // 新消息/运行状态变化时滚到底部。
    val scrollTarget = activeMessages.size + (if (run.isRunning) run.liveItems.size + 1 else 0) + (if (lastError != null) 1 else 0)
    LaunchedEffect(scrollTarget) {
        if (scrollTarget > 0) {
            runCatching { listState.animateScrollToItem(scrollTarget - 1) }
        }
    }

    val canSend = aiStatus.isLive && !run.isRunning && draft.isNotBlank()

    Box(modifier = modifier.fillMaxSize().background(colors.background)) {
        Column(modifier = Modifier.fillMaxSize().statusBarsPadding()) {
            // ---------------- Header（对齐 AssistantView.swift:641-674） ----------------
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.fillMaxWidth().padding(horizontal = AuralisSpacing.large, vertical = AuralisSpacing.small),
            ) {
                if (aiStatus.isLive) {
                    Icon(Icons.Filled.CheckCircle, contentDescription = null, tint = colors.success, modifier = Modifier.size(18.dp))
                    Spacer(Modifier.width(AuralisSpacing.small))
                    Text(
                        aiStatus.model,
                        style = MaterialTheme.typography.titleMedium,
                        color = colors.primaryText,
                        fontWeight = FontWeight.Medium,
                        maxLines = 1,
                        modifier = Modifier.weight(1f),
                    )
                } else {
                    Icon(Icons.Filled.Warning, contentDescription = null, tint = colors.warning, modifier = Modifier.size(18.dp))
                    Spacer(Modifier.width(AuralisSpacing.small))
                    Text(
                        if (aiStatus.enabled) stringResource(R.string.assistant_not_configured) else stringResource(R.string.assistant_disabled),
                        style = MaterialTheme.typography.titleMedium,
                        color = colors.primaryText,
                        fontWeight = FontWeight.Medium,
                        modifier = Modifier.weight(1f),
                    )
                }
                if (!aiStatus.isLive) {
                    IconButton(onClick = onOpenAiSettings) {
                        Icon(Icons.Filled.Settings, contentDescription = stringResource(R.string.assistant_configure), tint = colors.primaryText)
                    }
                }
                IconButton(onClick = onOpenSearch) {
                    Icon(Icons.Filled.Search, contentDescription = stringResource(R.string.assistant_search_library), tint = colors.primaryText)
                }
                IconButton(onClick = { sessionsOpen = true }) {
                    Icon(Icons.AutoMirrored.Filled.List, contentDescription = stringResource(R.string.assistant_sessions), tint = colors.primaryText)
                }
            }

            // ---------------- 消息流 ----------------
            LazyColumn(
                state = listState,
                modifier = Modifier.weight(1f).fillMaxWidth().padding(horizontal = AuralisSpacing.large),
            ) {
                if (activeMessages.isEmpty() && !run.isRunning && lastError == null) {
                    item {
                        EmptyState(isLive = aiStatus.isLive)
                    }
                }
                items(activeMessages.size) { index ->
                    val message = activeMessages[index]
                    when (message.role) {
                        StoredAssistantMessage.Role.User -> UserBubble(message.text)
                        StoredAssistantMessage.Role.Assistant -> AssistantBubble(message.text, message.createdAtMillis)
                    }
                }
                if (run.isRunning) {
                    item(key = "running-status") { RunningStatusRow(run.phase) }
                    items(run.liveItems.size) { index ->
                        when (val item = run.liveItems[index]) {
                            is AssistantLiveItem.ToolStatus -> ToolStatusRow(item)
                            is AssistantLiveItem.Reasoning -> Unit
                        }
                    }
                }
                lastError?.let { error ->
                    item(key = "error") { ErrorRow(error) }
                }
                item(key = "bottom-space") { Spacer(Modifier.height(AuralisSpacing.small)) }
            }

            // ---------------- 输入区 ----------------
            Column(modifier = Modifier.fillMaxWidth().navigationBarsPadding().padding(horizontal = AuralisSpacing.large, vertical = AuralisSpacing.small)) {
                if (run.isRunning) {
                    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
                        Text(
                            stringResource(R.string.assistant_running_with_phase, stringResource(run.phase.labelRes)),
                            style = MaterialTheme.typography.bodySmall,
                            color = colors.secondaryText,
                            modifier = Modifier.weight(1f),
                        )
                        TextButton(onClick = { coordinator.stop() }) { Text(stringResource(R.string.assistant_stop)) }
                    }
                }
                if (!aiStatus.isLive) {
                    Text(
                        if (aiStatus.enabled) stringResource(R.string.assistant_need_config_guide) else stringResource(R.string.assistant_disabled_guide),
                        style = MaterialTheme.typography.bodySmall,
                        color = colors.secondaryText,
                        modifier = Modifier.padding(bottom = AuralisSpacing.small),
                    )
                }
                Row(verticalAlignment = Alignment.Bottom) {
                    OutlinedTextField(
                        value = draft,
                        onValueChange = { draft = it },
                        placeholder = { Text(stringResource(R.string.assistant_input_placeholder)) },
                        modifier = Modifier.weight(1f),
                        minLines = 1,
                        maxLines = 4,
                        enabled = aiStatus.isLive,
                    )
                    Spacer(Modifier.width(AuralisSpacing.small))
                    if (run.isRunning) {
                        IconButton(onClick = { coordinator.stop() }) {
                            Icon(Icons.Filled.Stop, contentDescription = stringResource(R.string.assistant_stop), tint = colors.error, modifier = Modifier.size(28.dp))
                        }
                    } else {
                        IconButton(
                            onClick = {
                                coordinator.send(draft)
                                draft = ""
                            },
                            enabled = canSend,
                        ) {
                            Icon(
                                Icons.AutoMirrored.Filled.Send,
                                contentDescription = stringResource(R.string.assistant_send),
                                tint = if (canSend) colors.accent else colors.secondaryText.copy(alpha = 0.4f),
                                modifier = Modifier.size(28.dp),
                            )
                        }
                    }
                }
            }
        }

        // ---------------- 覆盖层：会话列表 / 操作日志 / 确认弹窗 ----------------
        if (sessionsOpen) {
            SessionsDialog(
                sessions = visibleSessions,
                showArchived = showArchived,
                onToggleShowArchived = { coordinator.showArchived.value = !coordinator.showArchived.value },
                onNew = { coordinator.newSession() },
                onSelect = { coordinator.selectSession(it); sessionsOpen = false },
                onRename = { id, title -> coordinator.renameSession(id, title) },
                onTogglePin = { coordinator.togglePin(it) },
                onToggleArchived = { coordinator.toggleArchived(it) },
                onClearMessages = { coordinator.clearSessionMessages(it) },
                onDelete = { coordinator.deleteSession(it) },
                onOpenActionLog = { sessionsOpen = false; actionLogOpen = true },
                onDismiss = { sessionsOpen = false },
            )
        }
        if (actionLogOpen) {
            ActionLogDialog(
                records = actions,
                onUndo = { coordinator.undoAction(it) },
                onDismiss = { actionLogOpen = false },
            )
        }
        consent?.let { request ->
            ConsentDialog(
                request = request,
                onAllowOnce = { coordinator.allowOnce() },
                onAllowAndRemember = { coordinator.allowAndRemember() },
                onCancel = { coordinator.cancelConsent() },
            )
        }
        confirm?.let { request ->
            OperationConfirmDialog(
                request = request,
                onApprove = { coordinator.approveConfirm() },
                onReject = { coordinator.rejectConfirm() },
            )
        }
    }
}

/** 空态（对齐 Swift：无目录/无会话时的引导；本地搜索与播放不依赖模型，照常可用）。 */
@Composable
private fun EmptyState(isLive: Boolean, modifier: Modifier = Modifier) {
    val colors = LocalAuralisTheme.current.colors
    Column(modifier = modifier.fillMaxWidth().padding(top = AuralisSpacing.huge)) {
        Text(
            stringResource(AuralisR.string.ai_assistant),
            style = MaterialTheme.typography.titleLarge,
            color = colors.primaryText,
        )
        Spacer(Modifier.height(AuralisSpacing.small))
        Text(
            if (isLive) stringResource(R.string.assistant_empty_live_hint) else stringResource(R.string.assistant_empty_offline_hint),
            style = MaterialTheme.typography.bodyMedium,
            color = colors.secondaryText,
        )
    }
}
