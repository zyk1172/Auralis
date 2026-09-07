package com.auralis.feature.assistant

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.ErrorOutline
import androidx.compose.material.icons.filled.Schedule
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.unit.dp
import com.auralis.core.designsystem.AuralisRadius
import com.auralis.core.designsystem.AuralisSpacing
import com.auralis.core.designsystem.LocalAuralisTheme
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/** 用户气泡：accent 22% 底、右对齐（对齐 Swift AssistantView）。 */
@Composable
internal fun UserBubble(text: String, modifier: Modifier = Modifier) {
    val colors = LocalAuralisTheme.current.colors
    Box(
        modifier = modifier
            .fillMaxWidth()
            .padding(vertical = AuralisSpacing.xSmall),
        contentAlignment = Alignment.CenterEnd,
    ) {
        Text(
            text = text,
            style = MaterialTheme.typography.bodyMedium,
            color = colors.primaryText,
            modifier = Modifier
                .background(colors.accent.copy(alpha = 0.22f), RoundedCornerShape(AuralisRadius.medium))
                .padding(horizontal = AuralisSpacing.medium, vertical = AuralisSpacing.small)
                .widthIn(max = 520.dp),
        )
    }
}

/** 助手气泡：elevated 底、左对齐 + 复制按钮（对齐 Swift AssistantView）。 */
@Composable
internal fun AssistantBubble(
    text: String,
    createdAtMillis: Long,
    modifier: Modifier = Modifier,
) {
    val colors = LocalAuralisTheme.current.colors
    val clipboard = LocalClipboardManager.current
    Column(modifier = modifier.fillMaxWidth().padding(vertical = AuralisSpacing.xSmall)) {
        Row(verticalAlignment = Alignment.Bottom) {
            Text(
                text = text,
                style = MaterialTheme.typography.bodyMedium,
                color = colors.primaryText,
                modifier = Modifier
                    .background(colors.elevated, RoundedCornerShape(AuralisRadius.medium))
                    .padding(horizontal = AuralisSpacing.medium, vertical = AuralisSpacing.small)
                    .widthIn(max = 520.dp),
            )
            Spacer(Modifier.width(AuralisSpacing.small))
            Icon(
                imageVector = Icons.Filled.ContentCopy,
                contentDescription = "复制",
                tint = colors.secondaryText,
                modifier = Modifier
                    .size(18.dp)
                    .clickable { clipboard.setText(AnnotatedString(text)) }
                    .padding(2.dp),
            )
        }
        Spacer(Modifier.height(AuralisSpacing.xSmall))
        Text(
            text = timeLabel(createdAtMillis),
            style = MaterialTheme.typography.labelSmall,
            color = colors.secondaryText,
        )
    }
}

/** 工具执行状态行（运行中瞬态；不写盘）。 */
@Composable
internal fun ToolStatusRow(item: AssistantLiveItem.ToolStatus, modifier: Modifier = Modifier) {
    val colors = LocalAuralisTheme.current.colors
    val iconColor = when (item.state) {
        AssistantLiveItem.ToolStatus.State.Running -> colors.secondaryText
        AssistantLiveItem.ToolStatus.State.Succeeded -> colors.success
        AssistantLiveItem.ToolStatus.State.Denied -> colors.error
    }
    val icon = when (item.state) {
        AssistantLiveItem.ToolStatus.State.Running -> Icons.Filled.Schedule
        AssistantLiveItem.ToolStatus.State.Succeeded -> Icons.Filled.Check
        AssistantLiveItem.ToolStatus.State.Denied -> Icons.Filled.Close
    }
    Column(modifier = modifier.fillMaxWidth().padding(vertical = AuralisSpacing.xSmall)) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier
                .background(colors.surface, RoundedCornerShape(AuralisRadius.small))
                .padding(horizontal = AuralisSpacing.medium, vertical = AuralisSpacing.small),
        ) {
            Icon(imageVector = icon, contentDescription = null, tint = iconColor, modifier = Modifier.size(16.dp))
            Spacer(Modifier.width(AuralisSpacing.small))
            Text(
                text = item.label,
                style = MaterialTheme.typography.bodyMedium,
                color = colors.primaryText,
            )
        }
        item.detail?.let { detail ->
            if (detail.isNotBlank()) {
                Spacer(Modifier.height(AuralisSpacing.xSmall))
                Text(
                    text = detail,
                    style = MaterialTheme.typography.bodySmall,
                    color = colors.secondaryText,
                    modifier = Modifier.padding(horizontal = AuralisSpacing.medium),
                )
            }
        }
    }
}

/** 运行中阶段行（思考中/执行操作/正在回复 + ▌光标语义的静态提示）。 */
@Composable
internal fun RunningStatusRow(phase: AssistantRunPhase, modifier: Modifier = Modifier) {
    val colors = LocalAuralisTheme.current.colors
    Text(
        text = phase.displayText,
        style = MaterialTheme.typography.bodyMedium,
        color = colors.secondaryText,
        modifier = modifier
            .fillMaxWidth()
            .padding(horizontal = AuralisSpacing.small, vertical = AuralisSpacing.small),
    )
}

/** 错误行（红字三角；AI 失败如实呈现，不伪装本地模式）。 */
@Composable
internal fun ErrorRow(text: String, modifier: Modifier = Modifier) {
    val colors = LocalAuralisTheme.current.colors
    Row(
        verticalAlignment = Alignment.Top,
        modifier = modifier
            .fillMaxWidth()
            .padding(vertical = AuralisSpacing.small),
        horizontalArrangement = Arrangement.spacedBy(AuralisSpacing.small),
    ) {
        Icon(
            imageVector = Icons.Filled.ErrorOutline,
            contentDescription = null,
            tint = colors.error,
            modifier = Modifier.size(16.dp),
        )
        Text(
            text = text,
            style = MaterialTheme.typography.bodySmall,
            color = colors.error,
            modifier = Modifier.weight(1f),
        )
    }
}

private fun timeLabel(millis: Long): String =
    runCatching { SimpleDateFormat("HH:mm", Locale.getDefault()).format(Date(millis)) }.getOrDefault("")
