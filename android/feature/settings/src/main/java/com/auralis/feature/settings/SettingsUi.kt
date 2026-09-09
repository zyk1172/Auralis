// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.feature.settings

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
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
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.auralis.core.designsystem.AuralisSpacing
import com.auralis.core.designsystem.LocalAuralisTheme
import com.auralis.core.designsystem.R as AuralisR
import java.util.Locale

/**
 * 设置模块公共 UI。
 *
 * Apple 端 `SettingsView` 使用 SwiftUI `Form` + `SettingsCategoryRow`：图标直接采用
 * hierarchical symbol，不额外包品牌色圆形底板；标题保持系统 body，副标题为 caption。
 * Android 这里复刻其信息层级和几何，只保留平台必要的返回/开关交互。
 */

/** 二级页顶栏：44dp 返回命中区 + 居中于同一行的标题。 */
@Composable
internal fun SettingsDetailTopBar(
    title: String,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = LocalAuralisTheme.current.colors
    Row(
        modifier = modifier
            .fillMaxWidth()
            .height(44.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        IconButton(onClick = onBack, modifier = Modifier.size(44.dp)) {
            Icon(
                Icons.AutoMirrored.Filled.ArrowBack,
                contentDescription = stringResource(AuralisR.string.back),
                tint = colors.accent,
                modifier = Modifier.size(20.dp),
            )
        }
        Text(
            title,
            style = MaterialTheme.typography.titleMedium,
            fontWeight = FontWeight.SemiBold,
            color = colors.primaryText,
            modifier = Modifier.weight(1f),
        )
        // 与左侧返回命中区严格对称，让标题视觉中心不被返回按钮推偏。
        Spacer(Modifier.size(44.dp))
    }
}

/**
 * 设置首页分类行。直接对应 Swift `Label { VStack(spacing: 2) } icon: { Image(...) }`。
 * 不使用 Android 自创的 36dp 圆形 icon chip。
 */
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
    val primary = if (enabled) colors.primaryText else colors.secondaryText.copy(alpha = 0.55f)
    val secondary = if (enabled) colors.secondaryText else colors.secondaryText.copy(alpha = 0.45f)

    Row(
        modifier = modifier
            .fillMaxWidth()
            .clickable(enabled = enabled, onClick = onClick)
            .padding(horizontal = AuralisSpacing.large, vertical = 11.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(
            icon,
            contentDescription = null,
            tint = if (enabled) colors.accent else secondary,
            modifier = Modifier.size(21.dp),
        )
        Spacer(Modifier.width(AuralisSpacing.medium))
        Column(
            modifier = Modifier.weight(1f),
        ) {
            Text(
                title,
                style = MaterialTheme.typography.bodyLarge,
                color = primary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                subtitle,
                style = MaterialTheme.typography.labelSmall.copy(
                    fontSize = 12.sp,
                    lineHeight = 16.sp,
                    fontWeight = FontWeight.Normal,
                ),
                color = secondary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        if (enabled) {
            Spacer(Modifier.width(AuralisSpacing.small))
            Icon(
                Icons.Filled.ChevronRight,
                contentDescription = null,
                tint = colors.secondaryText.copy(alpha = 0.72f),
                modifier = Modifier.size(14.dp),
            )
        }
    }
}

/** 带 Switch 的 Form 行。 */
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
        modifier = modifier
            .fillMaxWidth()
            .padding(horizontal = AuralisSpacing.large, vertical = AuralisSpacing.small),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Text(
                title,
                style = MaterialTheme.typography.bodyLarge,
                color = if (enabled) colors.primaryText else colors.secondaryText,
            )
            if (subtitle != null) {
                Text(
                    subtitle,
                    style = MaterialTheme.typography.labelSmall.copy(fontSize = 12.sp, lineHeight = 16.sp),
                    color = colors.secondaryText,
                )
            }
        }
        Spacer(Modifier.width(AuralisSpacing.medium))
        Switch(
            checked = checked,
            onCheckedChange = onCheckedChange,
            enabled = enabled,
            colors = SwitchDefaults.colors(
                checkedThumbColor = colors.background,
                checkedTrackColor = colors.accent,
                checkedBorderColor = colors.accent,
            ),
        )
    }
}

/** SwiftUI `Form Section` 头部的次级 caption 语义。 */
@Composable
internal fun SettingsSectionTitle(title: String, modifier: Modifier = Modifier) {
    val colors = LocalAuralisTheme.current.colors
    Text(
        title,
        style = MaterialTheme.typography.labelSmall.copy(
            fontSize = 12.sp,
            lineHeight = 16.sp,
            fontWeight = FontWeight.Normal,
        ),
        color = colors.secondaryText,
        modifier = modifier
            .fillMaxWidth()
            .padding(
                start = AuralisSpacing.large,
                end = AuralisSpacing.large,
                top = AuralisSpacing.large,
                bottom = AuralisSpacing.xSmall,
            ),
    )
}

/** Form 行之间的轻分隔线；左侧让出 symbol + spacing，接近系统 Form 的 inset separator。 */
@Composable
internal fun SettingsDivider(modifier: Modifier = Modifier) {
    val colors = LocalAuralisTheme.current.colors
    HorizontalDivider(
        thickness = 0.5.dp,
        color = colors.separator.copy(alpha = 0.72f),
        modifier = modifier.padding(start = 53.dp, end = AuralisSpacing.large),
    )
}

/** 说明文字（Swift caption + secondary）。 */
@Composable
internal fun SettingsCaption(text: String, modifier: Modifier = Modifier) {
    val colors = LocalAuralisTheme.current.colors
    Text(
        text,
        style = MaterialTheme.typography.labelSmall.copy(fontSize = 12.sp, lineHeight = 16.sp),
        color = colors.secondaryText,
        modifier = modifier.padding(
            horizontal = AuralisSpacing.large,
            vertical = AuralisSpacing.xSmall,
        ),
    )
}

/** 字节格式化（对齐 Swift ByteCountFormatter `.file` 的紧凑展示）。 */
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
