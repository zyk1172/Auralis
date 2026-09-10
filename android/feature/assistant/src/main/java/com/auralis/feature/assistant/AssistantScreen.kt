// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.feature.assistant

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
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
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.List
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
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
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.auralis.core.designsystem.AuralisChrome
import com.auralis.core.designsystem.AuralisChromeSurfaceRole
import com.auralis.core.designsystem.AuralisRadius
import com.auralis.core.designsystem.AuralisSpacing
import com.auralis.core.designsystem.LocalAuralisTheme
import com.auralis.core.designsystem.R as AuralisR
import com.auralis.core.designsystem.auralisChromeSurface

/**
 * AI 助手页（对齐 Swift `AssistantView`）。
 *
 * - Header：一行展示 Provider 状态/模型；按钮统一 44dp 命中框、19dp 光学图标；
 * - 消息流：用户主动上翻后不会被流式输出强行拉回底部，重新滑到底部后恢复跟随；
 * - 空会话不再常驻占据首屏的示例/标题文案，与 Apple 当前空态策略一致；
 * - 输入区：发送/停止随运行切换；AI 未配置时如实禁用发送并引导配置；
 * - AI 失败/未授权如实呈现，绝不伪装本地模式。
 */
@Composable
fun AssistantScreen(
    coordinator: AssistantCoordinator,
    onOpenSearch: () -> Unit,
    onOpenAiSettings: () -> Unit,
    collapseProgress: Float = 0f,
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
    var isFollowingOutput by remember { mutableStateOf(true) }

    /*
     * Apple AssistantView 只在用户仍靠近会话底部时跟随流式输出。
     * 这里不能简单在消息数变化时无条件 animateScrollToItem：用户上翻读旧消息时，
     * token/tool progress 的每次更新都会把阅读位置抢回底部。
     *
     * 只有“用户正在滚动”时才允许把 following 从 true 改成 false；普通的新消息导致
     * totalItemsCount 增长时不应误判用户离开底部。重新滑回末尾后自动恢复 following。
     */
    LaunchedEffect(listState) {
        snapshotFlow {
            val info = listState.layoutInfo
            val lastVisible = info.visibleItemsInfo.lastOrNull()?.index ?: -1
            Triple(listState.isScrollInProgress, info.totalItemsCount, lastVisible)
        }.collect { (scrolling, total, lastVisible) ->
            val atBottom = total == 0 || lastVisible >= total - 2
            if (scrolling) {
                isFollowingOutput = atBottom
            } else if (atBottom) {
                isFollowingOutput = true
            }
        }
    }

    val scrollTarget = activeMessages.size +
        (if (run.isRunning) run.liveItems.size + 1 else 0) +
        (if (lastError != null) 1 else 0)
    LaunchedEffect(scrollTarget) {
        if (scrollTarget > 0 && isFollowingOutput) {
            runCatching { listState.animateScrollToItem(scrollTarget - 1) }
        }
    }

    val canSend = aiStatus.isLive && !run.isRunning && draft.isNotBlank()

    Box(modifier = modifier.fillMaxSize().background(colors.background)) {
        Column(modifier = Modifier.fillMaxSize().statusBarsPadding()) {
            // ---------------- Header（对齐 Apple AssistantView.header） ----------------
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = AuralisSpacing.large, vertical = AuralisSpacing.small),
            ) {
                if (aiStatus.isLive) {
                    Icon(
                        Icons.Filled.CheckCircle,
                        contentDescription = null,
                        tint = colors.success,
                        modifier = Modifier.size(18.dp),
                    )
                    Spacer(Modifier.width(AuralisSpacing.small))
                    Text(
                        aiStatus.model,
                        style = MaterialTheme.typography.bodyMedium,
                        color = colors.success,
                        fontWeight = FontWeight.Medium,
                        maxLines = 1,
                        modifier = Modifier.weight(1f),
                    )
                } else {
                    Icon(
                        Icons.Filled.Warning,
                        contentDescription = null,
                        tint = colors.warning,
                        modifier = Modifier.size(18.dp),
                    )
                    Spacer(Modifier.width(AuralisSpacing.small))
                    Text(
                        if (aiStatus.enabled) stringResource(R.string.assistant_not_configured) else stringResource(R.string.assistant_disabled),
                        style = MaterialTheme.typography.bodyMedium,
                        color = colors.warning,
                        fontWeight = FontWeight.Medium,
                        maxLines = 1,
                        modifier = Modifier.weight(1f),
                    )
                }
                if (!aiStatus.isLive) {
                    TextButton(
                        onClick = onOpenAiSettings,
                        modifier = Modifier.height(44.dp),
                    ) {
                        Icon(
                            Icons.Filled.Settings,
                            contentDescription = null,
                            tint = colors.primaryText,
                            modifier = Modifier.size(16.dp),
                        )
                        Spacer(Modifier.width(AuralisSpacing.xSmall))
                        Text(
                            stringResource(R.string.assistant_configure),
                            style = MaterialTheme.typography.labelMedium,
                            color = colors.primaryText,
                        )
                    }
                }
                IconButton(onClick = onOpenSearch, modifier = Modifier.size(44.dp)) {
                    Icon(
                        Icons.Filled.Search,
                        contentDescription = stringResource(R.string.assistant_search_library),
                        tint = colors.primaryText,
                        modifier = Modifier.size(19.dp),
                    )
                }
                IconButton(onClick = { sessionsOpen = true }, modifier = Modifier.size(44.dp)) {
                    Icon(
                        Icons.AutoMirrored.Filled.List,
                        contentDescription = stringResource(R.string.assistant_sessions),
                        tint = colors.primaryText,
                        modifier = Modifier.size(19.dp),
                    )
                }
            }

            // ---------------- 消息流 ----------------
            LazyColumn(
                state = listState,
                modifier = Modifier
                    .weight(1f)
                    .fillMaxWidth()
                    .padding(horizontal = AuralisSpacing.large),
                contentPadding = androidx.compose.foundation.layout.PaddingValues(
                    bottom = AuralisSpacing.small,
                ),
            ) {
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

            AssistantInputDock(
                draft = draft,
                onDraftChange = { draft = it },
                canSend = canSend,
                isRunning = run.isRunning,
                aiAvailable = aiStatus.isLive,
                collapseProgress = collapseProgress,
                onSend = {
                    isFollowingOutput = true
                    coordinator.send(draft)
                    draft = ""
                },
                onStop = coordinator::stop,
            )
        }

        // ---------------- 覆盖层：会话列表 / 操作日志 / 确认弹窗 ----------------
        if (sessionsOpen) {
            SessionsDialog(
                sessions = visibleSessions,
                showArchived = showArchived,
                onToggleShowArchived = { coordinator.showArchived.value = !coordinator.showArchived.value },
                onNew = {
                    isFollowingOutput = true
                    coordinator.newSession()
                },
                onSelect = {
                    isFollowingOutput = true
                    coordinator.selectSession(it)
                    sessionsOpen = false
                },
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

/** iOS `DockAssistantInputBar` counterpart: fixed 56dp bar sharing the Dock's two endpoints. */
@Composable
private fun AssistantInputDock(
    draft: String,
    onDraftChange: (String) -> Unit,
    canSend: Boolean,
    isRunning: Boolean,
    aiAvailable: Boolean,
    collapseProgress: Float,
    onSend: () -> Unit,
    onStop: () -> Unit,
) {
    val colors = LocalAuralisTheme.current.colors
    val progress = collapseProgress.coerceIn(0f, 1f)
    val inputFocusRequester = remember { FocusRequester() }
    val inputInteraction = remember { MutableInteractionSource() }
    val horizontalInset = AuralisChrome.dockHorizontalPadding +
        (AuralisChrome.dockHeight + AuralisChrome.dockSpacing) * progress
    val bottomInset = AuralisChrome.dockBottomPadding +
        (AuralisChrome.dockHeight + AuralisChrome.dockSpacing) * (1f - progress)

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = horizontalInset)
            .navigationBarsPadding()
            .padding(bottom = bottomInset)
            .height(AuralisChrome.dockHeight)
            .auralisChromeSurface(
                RoundedCornerShape(AuralisRadius.large),
                AuralisChromeSurfaceRole.FloatingControl,
            )
            .padding(horizontal = AuralisChrome.miniPlayerHorizontalPadding),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(
            Icons.Filled.AutoAwesome,
            contentDescription = null,
            tint = colors.accent,
            modifier = Modifier.size(22.dp),
        )
        Spacer(Modifier.width(AuralisSpacing.medium))
        Box(
            modifier = Modifier
                .weight(1f)
                .clickable(
                    interactionSource = inputInteraction,
                    indication = null,
                    onClick = { inputFocusRequester.requestFocus() },
                ),
            contentAlignment = Alignment.CenterStart,
        ) {
            if (draft.isEmpty()) {
                Text(
                    text = stringResource(R.string.assistant_input_placeholder),
                    color = colors.secondaryText,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            BasicTextField(
                value = draft,
                onValueChange = onDraftChange,
                singleLine = true,
                enabled = aiAvailable && !isRunning,
                textStyle = MaterialTheme.typography.bodyLarge.copy(color = colors.primaryText),
                cursorBrush = SolidColor(colors.accent),
                modifier = Modifier
                    .fillMaxWidth()
                    .focusRequester(inputFocusRequester),
            )
        }
        IconButton(
            onClick = if (isRunning) onStop else onSend,
            enabled = if (isRunning) true else canSend,
            modifier = Modifier.size(44.dp),
        ) {
            Icon(
                imageVector = if (isRunning) Icons.Filled.Stop else Icons.AutoMirrored.Filled.Send,
                contentDescription = stringResource(if (isRunning) R.string.assistant_stop else R.string.assistant_send),
                tint = if (isRunning) colors.error else if (canSend) colors.accent else colors.secondaryText.copy(alpha = 0.4f),
                modifier = Modifier.size(24.dp),
            )
        }
    }
}
