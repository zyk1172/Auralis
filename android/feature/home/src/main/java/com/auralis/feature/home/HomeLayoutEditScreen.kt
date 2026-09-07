package com.auralis.feature.home

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.auralis.core.data.graph.AuralisGraph
import com.auralis.core.designsystem.AuralisRadius
import com.auralis.core.designsystem.AuralisSpacing
import com.auralis.core.designsystem.LocalAuralisTheme
import com.auralis.core.designsystem.R as AuralisR
import com.auralis.core.domain.HomeEntryPreference
import com.auralis.core.domain.HomeLayoutPreference
import com.auralis.core.domain.HomeModuleId
import com.auralis.core.domain.HomeQuickEntry
import kotlinx.coroutines.launch

/**
 * 首页布局编辑页（对齐 Apple `HomeLayoutEditView`）：
 * - 分「快捷入口」「内容模块」两区，每行「图标 + 名称 + 显示开关 + 排序按钮」；
 * - 改动即时生效并持久化（本地数组为唯一数据源，整组提交，避免拖动竞争崩溃）；
 * - 排序用上移/下移按钮（Android 无 SwiftUI List.onMove 的原生拖拽，交互差异见 parity）；
 * - 底部「恢复默认布局」带确认弹窗，只重置布局偏好，不删任何歌曲/缓存/播放记录。
 */
@Composable
fun HomeLayoutEditScreen(
    graph: AuralisGraph,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = LocalAuralisTheme.current.colors
    var quickEntries by remember { mutableStateOf<List<HomeEntryPreference>>(emptyList()) }
    var contentModules by remember { mutableStateOf<List<HomeEntryPreference>>(emptyList()) }
    var loaded by remember { mutableStateOf(false) }
    var confirmingReset by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()

    LaunchedEffect(graph) {
        quickEntries = graph.preferences.homeLayoutValue().quickEntries
        contentModules = graph.preferences.homeLayoutValue().contentModules
        loaded = true
    }

    fun persist(q: List<HomeEntryPreference>, c: List<HomeEntryPreference>) {
        scope.launch {
            graph.preferences.setHomeLayout(HomeLayoutPreference(q, c))
        }
    }

    fun move(list: List<HomeEntryPreference>, index: Int, delta: Int): List<HomeEntryPreference> {
        val target = index + delta
        if (index !in list.indices || target !in list.indices) return list
        val mutable = list.toMutableList()
        val item = mutable.removeAt(index)
        mutable.add(target, item)
        return mutable
    }

    Column(
        modifier = modifier
            .fillMaxSize()
            .background(colors.background)
            .statusBarsPadding(),
    ) {
        // 顶栏：返回 + 标题 + 「完成」（只关闭，配置已即时保存）。
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = AuralisSpacing.small, vertical = AuralisSpacing.small),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            IconButton(onClick = onBack) {
                Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = stringResource(AuralisR.string.back), tint = colors.primaryText)
            }
            Text(
                stringResource(R.string.home_edit_title),
                style = MaterialTheme.typography.titleLarge,
                color = colors.primaryText,
                modifier = Modifier.weight(1f),
            )
            TextButton(onClick = onBack) {
                Text(stringResource(AuralisR.string.done), fontWeight = FontWeight.SemiBold, color = colors.accent)
            }
        }
        HorizontalDivider(color = colors.separator)

        if (!loaded) {
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { }
        } else {
            LazyColumn(
                modifier = Modifier.weight(1f),
                contentPadding = androidx.compose.foundation.layout.PaddingValues(
                    bottom = AuralisSpacing.large,
                ),
            ) {
                item(key = "quick-header") {
                    SectionTitle(stringResource(R.string.home_layout_quick_entries))
                }
                itemsIndexed(quickEntries, key = { _, pref -> "quick-${pref.id}" }) { index, pref ->
                    val entryId = runCatching { HomeQuickEntry.valueOf(pref.id) }.getOrNull()
                    LayoutRow(
                        icon = entryId?.icon,
                        title = entryId?.let { stringResource(it.titleRes) } ?: pref.id,
                        visible = pref.visible,
                        canMoveUp = index > 0,
                        canMoveDown = index < quickEntries.lastIndex,
                        onToggle = { value ->
                            val updated = quickEntries.mapIndexed { i, p ->
                                if (i == index) p.copy(visible = value) else p
                            }
                            quickEntries = updated
                            persist(updated, contentModules)
                        },
                        onMoveUp = {
                            val updated = move(quickEntries, index, -1)
                            quickEntries = updated
                            persist(updated, contentModules)
                        },
                        onMoveDown = {
                            val updated = move(quickEntries, index, +1)
                            quickEntries = updated
                            persist(updated, contentModules)
                        },
                    )
                    HorizontalDivider(color = colors.separator)
                }
                item(key = "content-header") {
                    SectionTitle(stringResource(R.string.home_layout_content_modules))
                }
                itemsIndexed(contentModules, key = { _, pref -> "content-${pref.id}" }) { index, pref ->
                    val moduleId = runCatching { HomeModuleId.valueOf(pref.id) }.getOrNull()
                    LayoutRow(
                        icon = moduleId?.icon,
                        title = moduleId?.let { stringResource(it.titleRes) } ?: pref.id,
                        visible = pref.visible,
                        canMoveUp = index > 0,
                        canMoveDown = index < contentModules.lastIndex,
                        onToggle = { value ->
                            val updated = contentModules.mapIndexed { i, p ->
                                if (i == index) p.copy(visible = value) else p
                            }
                            contentModules = updated
                            persist(quickEntries, updated)
                        },
                        onMoveUp = {
                            val updated = move(contentModules, index, -1)
                            contentModules = updated
                            persist(quickEntries, updated)
                        },
                        onMoveDown = {
                            val updated = move(contentModules, index, +1)
                            contentModules = updated
                            persist(quickEntries, updated)
                        },
                    )
                    HorizontalDivider(color = colors.separator)
                }
            }
        }

        // 底部「恢复默认布局」（危险样式但只重置布局偏好）。
        TextButton(
            onClick = { confirmingReset = true },
            modifier = Modifier
                .align(Alignment.CenterHorizontally)
                .padding(vertical = AuralisSpacing.medium),
        ) {
            Text(stringResource(R.string.home_reset_layout), color = colors.error)
        }
    }

    if (confirmingReset) {
        AlertDialog(
            onDismissRequest = { confirmingReset = false },
            title = { Text(stringResource(R.string.home_reset_layout_confirm_title)) },
            text = { Text(stringResource(R.string.home_reset_layout_message)) },
            confirmButton = {
                TextButton(onClick = {
                    confirmingReset = false
                    scope.launch {
                        graph.preferences.restoreDefaultHomeLayout()
                        val defaults = graph.preferences.homeLayoutValue()
                        quickEntries = defaults.quickEntries
                        contentModules = defaults.contentModules
                    }
                }) { Text(stringResource(R.string.home_reset_layout_confirm), color = colors.error) }
            },
            dismissButton = {
                TextButton(onClick = { confirmingReset = false }) { Text(stringResource(AuralisR.string.cancel)) }
            },
            containerColor = colors.elevated,
        )
    }
}

@Composable
private fun SectionTitle(title: String) {
    val colors = LocalAuralisTheme.current.colors
    Text(
        title,
        style = MaterialTheme.typography.labelMedium,
        color = colors.secondaryText,
        modifier = Modifier.padding(
            start = AuralisSpacing.large,
            top = AuralisSpacing.large,
            bottom = AuralisSpacing.small,
        ),
    )
}

@Composable
private fun LayoutRow(
    icon: androidx.compose.ui.graphics.vector.ImageVector?,
    title: String,
    visible: Boolean,
    canMoveUp: Boolean,
    canMoveDown: Boolean,
    onToggle: (Boolean) -> Unit,
    onMoveUp: () -> Unit,
    onMoveDown: () -> Unit,
) {
    val colors = LocalAuralisTheme.current.colors
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = AuralisSpacing.large, vertical = AuralisSpacing.small),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (icon != null) {
            Icon(
                icon,
                contentDescription = null,
                tint = colors.accent,
                modifier = Modifier.size(22.dp),
            )
            Spacer(Modifier.width(AuralisSpacing.medium))
        }
        Text(
            title,
            style = MaterialTheme.typography.bodyLarge,
            color = if (visible) colors.primaryText else colors.secondaryText,
            modifier = Modifier.weight(1f),
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
        IconButton(
            onClick = onMoveUp,
            enabled = canMoveUp,
            modifier = Modifier.size(32.dp),
        ) {
            Icon(
                Icons.Filled.KeyboardArrowUp,
                contentDescription = stringResource(AuralisR.string.move_up),
                tint = if (canMoveUp) colors.primaryText else colors.separator,
            )
        }
        IconButton(
            onClick = onMoveDown,
            enabled = canMoveDown,
            modifier = Modifier.size(32.dp),
        ) {
            Icon(
                Icons.Filled.KeyboardArrowDown,
                contentDescription = stringResource(AuralisR.string.move_down),
                tint = if (canMoveDown) colors.primaryText else colors.separator,
            )
        }
        Switch(
            checked = visible,
            onCheckedChange = onToggle,
            modifier = Modifier.padding(start = AuralisSpacing.xSmall),
        )
    }
}
