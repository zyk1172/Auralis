// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.mobile.shell

import androidx.compose.animation.core.FiniteAnimationSpec
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.snap
import androidx.compose.animation.core.spring
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.Home
import androidx.compose.material.icons.filled.LibraryMusic
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import com.auralis.core.designsystem.AuralisChrome
import com.auralis.core.designsystem.AuralisChromeSurfaceRole
import com.auralis.core.designsystem.AuralisColorScheme
import com.auralis.core.designsystem.AuralisSpacing
import com.auralis.core.designsystem.LocalAuralisTheme
import com.auralis.core.designsystem.LocalReduceMotion
import com.auralis.core.designsystem.auralisChromeSurface
import kotlin.math.roundToInt

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
 * Android counterpart of Apple `MainTabBarContent`.
 *
 * The selected state is one neutral capsule that slides underneath three fixed, equal-width tabs;
 * it is not three independent accent pills. Horizontal drag is locked to one adjacent section and
 * commits at 32% of one tab width, matching the iOS gesture. Vertical drags remain available to the
 * parent morphing-dock gesture because this detector is orientation-locked to horizontal travel.
 */
@Composable
fun BottomDock(
    selected: AppSection,
    onSelect: (AppSection) -> Unit,
    modifier: Modifier = Modifier,
) {
    val theme = LocalAuralisTheme.current
    val colors = theme.colors
    val reduceMotion = LocalReduceMotion.current
    val density = LocalDensity.current
    val shape = RoundedCornerShape(percent = 50)
    val items = remember { listOf(AppSection.Home, AppSection.Library, AppSection.Assistant) }
    val selectedIndex = items.indexOf(selected).coerceAtLeast(0)
    val dragOffsetPx = remember { mutableFloatStateOf(0f) }

    BoxWithConstraints(
        modifier = modifier
            .height(AuralisChrome.dockHeight)
            .auralisChromeSurface(shape, AuralisChromeSurfaceRole.Navigation)
            .padding(horizontal = AuralisSpacing.small),
    ) {
        val itemWidth = maxWidth / items.size
        val itemWidthPx = with(density) { itemWidth.toPx() }
        val selectedBasePx = selectedIndex * itemWidthPx
        val selectionSpec: FiniteAnimationSpec<Float> = if (reduceMotion) {
            snap()
        } else {
            // SwiftUI `.snappy(duration: 0.30, extraBounce: 0.08)` has no one-to-one Compose API.
            // A short, lightly under-damped spring preserves the same terminal motion and small overshoot.
            spring(dampingRatio = 0.78f, stiffness = 560f)
        }
        val animatedBasePx by animateFloatAsState(
            targetValue = selectedBasePx,
            animationSpec = selectionSpec,
            label = "auralis-dock-selection-x",
        )

        val selectionFill = colors.primaryText.copy(
            alpha = if (theme.colorScheme == AuralisColorScheme.Dark) 0.17f else 0.09f,
        )
        val selectionShadow = if (theme.colorScheme == AuralisColorScheme.Dark) 0.18f else 0.05f

        Box(
            modifier = Modifier
                .width(itemWidth)
                .fillMaxHeight()
                .offset {
                    IntOffset(
                        x = (animatedBasePx + dragOffsetPx.floatValue).roundToInt(),
                        y = 0,
                    )
                }
                .shadow(
                    elevation = 7.dp,
                    shape = shape,
                    clip = false,
                    ambientColor = androidx.compose.ui.graphics.Color.Black.copy(alpha = selectionShadow),
                    spotColor = androidx.compose.ui.graphics.Color.Black.copy(alpha = selectionShadow),
                )
                .background(selectionFill, shape),
        )

        Row(
            modifier = Modifier
                .fillMaxSize()
                .pointerInput(selectedIndex, itemWidthPx, reduceMotion) {
                    if (itemWidthPx <= 0f) return@pointerInput
                    detectHorizontalDragGestures(
                        onDragStart = { dragOffsetPx.floatValue = 0f },
                        onHorizontalDrag = { change, amount ->
                            change.consume()
                            val minimum = if (selectedIndex < items.lastIndex) -itemWidthPx else 0f
                            val maximum = if (selectedIndex > 0) itemWidthPx else 0f
                            dragOffsetPx.floatValue =
                                (dragOffsetPx.floatValue + amount).coerceIn(minimum, maximum)
                        },
                        onDragEnd = {
                            val offset = dragOffsetPx.floatValue
                            val targetIndex = when {
                                offset < -itemWidthPx * 0.32f -> (selectedIndex + 1).coerceAtMost(items.lastIndex)
                                offset > itemWidthPx * 0.32f -> (selectedIndex - 1).coerceAtLeast(0)
                                else -> selectedIndex
                            }
                            dragOffsetPx.floatValue = 0f
                            if (targetIndex != selectedIndex) onSelect(items[targetIndex])
                        },
                        onDragCancel = { dragOffsetPx.floatValue = 0f },
                    )
                },
            verticalAlignment = Alignment.CenterVertically,
        ) {
            items.forEach { section ->
                DockItem(
                    label = stringResource(section.labelRes),
                    icon = section.symbol(),
                    selected = selected == section,
                    onClick = {
                        dragOffsetPx.floatValue = 0f
                        onSelect(section)
                    },
                    modifier = Modifier.weight(1f),
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
    modifier: Modifier = Modifier,
) {
    val colors = LocalAuralisTheme.current.colors
    val interaction = remember { MutableInteractionSource() }
    val tint = if (selected) colors.accent else colors.secondaryText

    Column(
        modifier = modifier
            .fillMaxSize()
            .clickable(
                interactionSource = interaction,
                indication = null,
                onClick = onClick,
            ),
        verticalArrangement = androidx.compose.foundation.layout.Arrangement.Center,
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
            maxLines = 1,
        )
    }
}
