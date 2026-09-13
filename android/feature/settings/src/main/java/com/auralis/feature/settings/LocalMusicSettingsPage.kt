// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.feature.settings

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import com.auralis.core.data.graph.AuralisGraph
import com.auralis.core.data.graph.localMusicLibrary
import com.auralis.core.designsystem.LocalAuralisTheme
import kotlinx.coroutines.launch

/** Local-library management is exposed only from Settings and shared by phone + TV. */
@Composable
internal fun LocalMusicSettingsPage(
    graph: AuralisGraph,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = LocalAuralisTheme.current.colors
    val sources by graph.localMusicLibrary.sources.collectAsState()
    val tracks by graph.localMusicLibrary.tracks.collectAsState()
    val scope = rememberCoroutineScope()
    var scanStatus by remember { mutableStateOf<String?>(null) }
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocumentTree()) { uri ->
        if (uri != null) {
            scope.launch {
                runCatching {
                    graph.localMusicLibrary.addTree(uri)
                    graph.localMusicLibrary.scanAll()
                }.onSuccess {
                    scanStatus = "扫描 ${it.discoveredFiles} 个文件，失败 ${it.failedFiles} 个"
                }.onFailure {
                    scanStatus = "无法读取所选音乐文件夹"
                }
            }
        }
    }

    SettingsPageContainer(modifier = modifier) {
        LazyColumn(Modifier.fillMaxSize()) {
            item { SettingsDetailTopBar(title = "本地音乐", onBack = onBack) }
            item { SettingsSectionTitle("本地音乐库") }
            item { SettingsValueRow(title = "已扫描歌曲", value = tracks.size.toString()) }
            item {
                TextButton(onClick = {
                    runCatching { picker.launch(null) }
                        .onFailure { scanStatus = "此设备没有可用的文件夹选择器" }
                }) {
                    Text("添加音乐文件夹")
                }
            }
            item {
                TextButton(
                    enabled = sources.isNotEmpty(),
                    onClick = {
                        scope.launch {
                            runCatching { graph.localMusicLibrary.scanAll() }
                                .onSuccess { scanStatus = "扫描 ${it.discoveredFiles} 个文件，失败 ${it.failedFiles} 个" }
                                .onFailure { scanStatus = "扫描失败" }
                        }
                    },
                ) {
                    Text("重新扫描全部")
                }
            }
            scanStatus?.let { status -> item { SettingsCaption(status) } }
            item { SettingsSectionTitle("来源") }
            if (sources.isEmpty()) {
                item { SettingsCaption("尚未添加本地音乐文件夹。服务器下载会自动进入 Auralis 管理的本地音乐库。") }
            }
            sources.forEach { source ->
                item {
                    SettingsValueRow(title = source.displayName, value = "已持久授权")
                    TextButton(onClick = { graph.localMusicLibrary.removeSource(source) }) {
                        Text("移除来源")
                    }
                }
            }
            item { SettingsSectionTitle("下载") }
            item {
                Text(
                    "服务器下载保存到 LocalMusic/downloads。完成后建立本地 canonical 身份，并保留服务器身份作为兼容别名。",
                    style = MaterialTheme.typography.bodySmall,
                    color = colors.secondaryText,
                )
            }
        }
    }
}
