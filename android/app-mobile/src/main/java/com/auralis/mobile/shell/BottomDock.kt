// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.mobile.shell

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.weight
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.Home
import androidx.compose.material.icons.filled.LibraryMusic
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.auralis.core.designsystem.AuralisChrome
import com.auralis.core.designsystem.AuralisChromeSurfaceRole
import com.auralis.core.designsystem.AuralisRadius
import com.auralis.core.designsystem.AuralisSpacing
import com.auralis.core.designsystem.LocalAuralisTheme
import com.auralis.core.designsystem.auralisChromeSurface

/**
 * 一级图标语义对齐 Apple `AppSection.symbol`：
 * Home = house.fill；Library = square.stack.fill；Assistant = sparkles。
 * Material Symbols 不是 SF Symbols 的同一字形，但保持相同视觉语义和 19pt 光学尺寸。
 */
private fun AppSection.symbol(): ImageVector = when (this) {
    AppSection.Home -> Icons.Filled.Home
    AppSection.Library -> Icons.Filled.LibraryMusic
    AppSection.Assistant -> Icons.Filled.AutoAwesome
}

/**
 * 展开态底部 Dock，对齐 Apple `MainTabBarContent` / `BottomGlassBarShell`：
 * - 高 56；三个入口等分；VStack spacing=4；图标 19 medium；标题 caption2；
 * - 选中高亮是栏内胶囊，不改变栏整体几何；
 * - 三个入口使用同一结构，Assistant 在**展开态**不再被 Android 特化成独立 44dp 圆钮；
 * - 材质由 ThemeMaterials.navigation 决定，不再固定为实色 elevated。
 */
@Composable
fun BottomDock(
    selected: AppSection,
    onSelect: (AppSection) -> Unit,
    modifier: Modifier = Modifier,
) {
    val shape = RoundedCornerShape(AuralisRadius.large)
    val items = listOf(AppSection.Home, AppSection.Library, AppSection.Assistant)

    Row(
        modifier = modifier
            .height(AuralisChrome.dockHeight)
            .auralisChromeSurface(shape, AuralisChromeSurfaceRole.Navigation)
            .padding(horizontal = AuralisSpacing.small),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        items.forEach { section ->
            DockItem(
                label = stringResource(section.labelRes),
                icon = section.symbol(),
                selected = selected == section,
                onClick = { onSelect(section) },
                modifier = Modifier.weight(1f),
            )
        }
    }
}

@Composable
private fun DockItem(
    label: String,
    icon: ImageVector,
    selected: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = LocalAuralisTheme.current.colors
    val interaction = remember { MutableInteractionSource() }
    val tint = if (selected) colors.accent else colors.primaryText
    val selectionShape = RoundedCornerShape(18.dp)

    Column(
        modifier = modifier
            .fillMaxSize()
            .padding(horizontal = 3.dp, vertical = 4.dp)
            .background(
                color = if (selected) colors.accent.copy(alpha = 0.14f) else Color.Transparent,
                shape = selectionShape,
            )
            .clickable(
                interactionSource = interaction,
                indication = null,
                onClick = onClick,
            ),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Icon(
            imageVector = icon,
            contentDescription = label,
            tint = tint,
            modifier = Modifier.size(19.dp),
        )
        Spacer(Modifier.height(4.dp))
        Text(
            text = label,
            style = MaterialTheme.typography.labelSmall,
            color = tint,
            fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal,
            maxLines = 1,
        )
    }
}
