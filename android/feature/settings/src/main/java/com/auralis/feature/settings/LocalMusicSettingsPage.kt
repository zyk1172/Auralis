// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.feature.settings

import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import com.auralis.core.designsystem.LocalAuralisTheme

/** Local library configuration is intentionally exposed only from Settings. */
@Composable
internal fun LocalMusicSettingsPage(
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = LocalAuralisTheme.current.colors
    SettingsPageContainer(modifier = modifier) {
        LazyColumn(Modifier.fillMaxSize()) {
            item { SettingsDetailTopBar(title = "本地音乐", onBack = onBack) }
            item { SettingsSectionTitle("本地音乐基础架构") }
            item {
                Text(
                    "本地音乐来源、扫描状态、重新扫描和存储位置统一在设置中管理。文件夹授权与扫描将在下一阶段启用。",
                    style = MaterialTheme.typography.bodyMedium,
                    color = colors.secondaryText,
                )
            }
            item { SettingsSectionTitle("来源") }
            item { SettingsCaption("尚未添加本地音乐来源。") }
        }
    }
}
