package com.auralis.mobile.shell

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.Home
import androidx.compose.material.icons.filled.LibraryMusic
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.auralis.core.designsystem.AuralisChrome
import com.auralis.core.designsystem.AuralisRadius
import com.auralis.core.designsystem.AuralisSpacing
import com.auralis.core.designsystem.LocalAuralisTheme
import com.auralis.mobile.R
import com.auralis.core.designsystem.R as AuralisR

/**
 * 一级图标（对齐 Apple AppSection.symbol）：
 * Home = house.fill → Home；Library = square.stack.fill → LibraryMusic；
 * Assistant = sparkles → AutoAwesome（圆钮突出）。
 */
private fun AppSection.symbol(): ImageVector = when (this) {
    AppSection.Home -> Icons.Filled.Home
    AppSection.Library -> Icons.Filled.LibraryMusic
    AppSection.Assistant -> Icons.Filled.AutoAwesome
}

/**
 * 底部 Dock（对齐 Apple BottomDock）：
 * - 悬浮 overlay，宽屏最大约 760dp 并居中，不横贯整屏；
 * - 三个一级分区：Home / Library / Assistant（圆形 accent 钮）；
 * - 底部内边距 + 系统导航条安全区。
 */
@Composable
fun BottomDock(
    selected: AppSection,
    onSelect: (AppSection) -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = LocalAuralisTheme.current.colors
    val items = listOf(AppSection.Home, AppSection.Library, AppSection.Assistant)

    Row(
        modifier = modifier
            .height(AuralisChrome.dockHeight)
            .background(colors.elevated, RoundedCornerShape(AuralisRadius.large))
            .padding(horizontal = AuralisSpacing.small),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.SpaceEvenly,
    ) {
        items.forEach { section ->
            if (section == AppSection.Assistant) {
                AssistantDockButton(
                    selected = selected == section,
                    onClick = { onSelect(section) },
                )
            } else {
                DockItem(
                    label = stringResource(section.labelRes),
                    icon = section.symbol(),
                    selected = selected == section,
                    onClick = { onSelect(section) },
                )
            }
        }
    }
}

@Composable
private fun DockItem(
    label: String,
    icon: ImageVector,
    selected: Boolean,
    onClick: () -> Unit,
) {
    val colors = LocalAuralisTheme.current.colors
    val tint = if (selected) colors.primaryText else colors.secondaryText
    Column(
        modifier = Modifier
            .height(AuralisChrome.dockHeight)
            .width(88.dp)
            .clickable(onClick = onClick),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Icon(icon, contentDescription = label, tint = tint, modifier = Modifier.size(22.dp))
        Spacer(Modifier.height(2.dp))
        Text(
            label,
            style = MaterialTheme.typography.labelSmall,
            color = tint,
            fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal,
        )
    }
}

/** AI 助手 = 圆形 accent 按钮（对齐 Dock 圆钮视觉）。 */
@Composable
private fun AssistantDockButton(
    selected: Boolean,
    onClick: () -> Unit,
) {
    val colors = LocalAuralisTheme.current.colors
    val bg = if (selected) colors.accent else colors.accent.copy(alpha = 0.18f)
    val tint = if (selected) colors.background else colors.accent
    Box(
        modifier = Modifier
            .width(88.dp)
            .height(AuralisChrome.dockHeight),
        contentAlignment = Alignment.Center,
    ) {
        Box(
            modifier = Modifier
                .size(44.dp)
                .background(bg, CircleShape)
                .clickable(onClick = onClick),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                Icons.Filled.AutoAwesome,
                contentDescription = stringResource(AuralisR.string.ai_assistant),
                tint = tint,
                modifier = Modifier.size(22.dp),
            )
        }
    }
}
