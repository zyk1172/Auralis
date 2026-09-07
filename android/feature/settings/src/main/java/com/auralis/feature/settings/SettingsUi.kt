package com.auralis.feature.settings

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.auralis.core.designsystem.AuralisSpacing
import com.auralis.core.designsystem.LocalAuralisTheme
import com.auralis.core.designsystem.R as AuralisR
import java.util.Locale

/**
 * 设置模块公共 UI（对齐 Swift `SettingsCategoryRow` / `SettingsDetailForm`）。
 * 行语义：title 主文案 + subtitle 副文案 + 可选开关/箭头；禁用态用 [enabled] 表达，
 * 不做假按钮。
 */

/** 设置二级页顶栏：返回 + 标题 + 分隔线。 */
@Composable
internal fun SettingsDetailTopBar(
    title: String,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = LocalAuralisTheme.current.colors
    Row(
        modifier = modifier.fillMaxWidth().padding(horizontal = AuralisSpacing.small, vertical = AuralisSpacing.xSmall),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        IconButton(onClick = onBack) {
            Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = stringResource(AuralisR.string.back), tint = colors.primaryText)
        }
        Text(title, style = MaterialTheme.typography.titleMedium, color = colors.primaryText)
    }
}

/** 带图标设置行（点击跳转）。 */
@Composable
internal fun SettingsCategoryRow(
    title: String,
    subtitle: String,
    icon: ImageVector,
    onClick: () -> Unit,
    enabled: Boolean = true,
    modifier: Modifier = Modifier,
) {
    val colors = LocalAuralisTheme.current.colors
    Row(
        modifier = modifier
            .fillMaxWidth()
            .clickable(enabled = enabled, onClick = onClick)
            .padding(horizontal = AuralisSpacing.large, vertical = AuralisSpacing.medium),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            modifier = Modifier
                .size(36.dp)
                .background(colors.surface, CircleShape),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                icon,
                contentDescription = null,
                tint = if (enabled) colors.accent else colors.secondaryText,
                modifier = Modifier.size(18.dp),
            )
        }
        Spacer(Modifier.width(AuralisSpacing.medium))
        Column(Modifier.weight(1f)) {
            Text(
                title,
                style = MaterialTheme.typography.bodyLarge,
                color = if (enabled) colors.primaryText else colors.secondaryText,
            )
            Text(
                subtitle,
                style = MaterialTheme.typography.bodySmall,
                color = colors.secondaryText,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        if (enabled) {
            Icon(Icons.Filled.ChevronRight, contentDescription = null, tint = colors.secondaryText)
        }
    }
}

/** 带 Switch 的设置行：Switch 直接驱动 [checked]/[onCheckedChange]，不经过点击态。 */
@Composable
internal fun SettingsSwitchRow(
    title: String,
    subtitle: String? = null,
    checked: Boolean,
    onCheckedChange: (Boolean) -> Unit,
    enabled: Boolean = true,
    modifier: Modifier = Modifier,
) {
    val colors = LocalAuralisTheme.current.colors
    Row(
        modifier = modifier.fillMaxWidth().padding(horizontal = AuralisSpacing.large, vertical = AuralisSpacing.small),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Text(
                title,
                style = MaterialTheme.typography.bodyMedium,
                color = if (enabled) colors.primaryText else colors.secondaryText,
            )
            if (subtitle != null) {
                Text(
                    subtitle,
                    style = MaterialTheme.typography.bodySmall,
                    color = colors.secondaryText,
                )
            }
        }
        Spacer(Modifier.width(AuralisSpacing.medium))
        Switch(checked = checked, onCheckedChange = onCheckedChange, enabled = enabled)
    }
}

/** 设置分类标题（对齐 Swift Form Section 头）。 */
@Composable
internal fun SettingsSectionTitle(title: String, modifier: Modifier = Modifier) {
    val colors = LocalAuralisTheme.current.colors
    Text(
        title,
        style = MaterialTheme.typography.labelMedium,
        color = colors.secondaryText,
        modifier = modifier
            .fillMaxWidth()
            .padding(start = AuralisSpacing.large, top = AuralisSpacing.large, bottom = AuralisSpacing.xSmall),
    )
}

/** 行分隔线。 */
@Composable
internal fun SettingsDivider(modifier: Modifier = Modifier) {
    val colors = LocalAuralisTheme.current.colors
    HorizontalDivider(
        thickness = 0.5.dp,
        color = colors.separator,
        modifier = modifier.padding(horizontal = AuralisSpacing.large),
    )
}

/** 说明文字（对齐 Swift caption + secondary）。 */
@Composable
internal fun SettingsCaption(text: String, modifier: Modifier = Modifier) {
    val colors = LocalAuralisTheme.current.colors
    Text(
        text,
        style = MaterialTheme.typography.bodySmall,
        color = colors.secondaryText,
        modifier = modifier.padding(horizontal = AuralisSpacing.large, vertical = AuralisSpacing.xSmall),
    )
}

/** 字节格式化（对齐 Swift ByteCountFormatter .file）。 */
internal fun formatBytes(bytes: Long): String {
    if (bytes <= 0) return "0 KB"
    val units = arrayOf("B", "KB", "MB", "GB")
    var value = bytes.toDouble()
    var unit = 0
    while (value >= 1024 && unit < units.lastIndex) {
        value /= 1024
        unit++
    }
    return if (unit == 0) "${bytes} B" else String.format(Locale.US, "%.1f %s", value, units[unit])
}

/** 背景页容器（设置各页共用）。 */
@Composable
internal fun SettingsPageContainer(
    modifier: Modifier = Modifier,
    content: @Composable () -> Unit,
) {
    val colors = LocalAuralisTheme.current.colors
    Column(
        modifier = modifier
            .fillMaxSize()
            .background(colors.background)
            .statusBarsPadding(),
    ) {
        content()
    }
}
