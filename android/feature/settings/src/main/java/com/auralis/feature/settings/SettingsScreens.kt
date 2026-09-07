package com.auralis.feature.settings

import android.content.pm.PackageManager
import android.os.Build
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.VolumeUp
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Dns
import androidx.compose.material.icons.filled.Palette
import androidx.compose.material.icons.filled.Storage
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Slider
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.auralis.core.data.graph.AuralisGraph
import com.auralis.core.designsystem.AuralisRadius
import com.auralis.core.designsystem.AuralisSpacing
import com.auralis.core.designsystem.AuralisThemeController
import com.auralis.core.designsystem.BuiltInThemes
import com.auralis.core.designsystem.LocalAuralisTheme
import com.auralis.core.domain.ReplayGainMode
import com.auralis.core.domain.ServerId
import com.auralis.core.image.clearArtworkCaches
import com.auralis.core.opensubsonic.StreamQualitySettings
import java.io.File
import java.util.Locale
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch

/**
 * 设置（对齐 Swift `SettingsView` 主表 + `SettingsDetailPages` 子页）。
 *
 * 结构：
 * - 设置：服务器 / AI 助手（S8 前如实置灰）/ 播放与音质 / 数据与备份
 * - 外观：首页布局（S3 已有）/ 主题（DataStore + 即时应用）
 * - 关于：版本（PackageManager 真实值）
 *
 * 每个控件都有真实读写（DataStore / 目录统计 / DAO 清理 / coil 缓存），无假开关。
 */
@Composable
fun SettingsScreen(
    graph: AuralisGraph,
    onBack: () -> Unit,
    onOpenServers: () -> Unit,
    onEditHomeLayout: () -> Unit,
    onOpenAiSettings: () -> Unit,
    modifier: Modifier = Modifier,
) {
    var page by remember { mutableStateOf<SettingsPage?>(null) }
    BackHandler(enabled = page != null) { page = null }

    when (page) {
        null -> SettingsRootPage(
            graph = graph,
            onBack = onBack,
            onOpenServers = onOpenServers,
            onEditHomeLayout = onEditHomeLayout,
            onOpenAiSettings = onOpenAiSettings,
            onOpenQuality = { page = SettingsPage.Quality },
            onOpenData = { page = SettingsPage.Data },
            onOpenTheme = { page = SettingsPage.Theme },
            modifier = modifier,
        )

        SettingsPage.Quality -> QualitySettingsPage(graph = graph, onBack = { page = null }, modifier = modifier)
        SettingsPage.Data -> DataAndBackupPage(graph = graph, onBack = { page = null }, modifier = modifier)
        SettingsPage.Theme -> ThemeSettingsPage(graph = graph, onBack = { page = null }, modifier = modifier)
    }
}

private enum class SettingsPage { Quality, Data, Theme }

// ================================================================== 根页

@Composable
private fun SettingsRootPage(
    graph: AuralisGraph,
    onBack: () -> Unit,
    onOpenServers: () -> Unit,
    onEditHomeLayout: () -> Unit,
    onOpenAiSettings: () -> Unit,
    onOpenQuality: () -> Unit,
    onOpenData: () -> Unit,
    onOpenTheme: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = LocalAuralisTheme.current.colors
    val scope = rememberCoroutineScope()

    // 服务器行副标题：激活服务器名 + 已同步歌曲数（真实查询，无激活则引导文案）。
    var serverSubtitle by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(Unit) {
        serverSubtitle = null
        val servers = runCatching { graph.catalogRepository.servers() }.getOrDefault(emptyList())
        val activeId = runCatching { graph.preferences.activeServerIdValue() }.getOrNull()
        if (activeId == null) {
            serverSubtitle = "连接音乐服务器与下载服务"
        } else {
            val account = servers.firstOrNull { it.id.value == activeId }
            val count = runCatching { graph.catalogRepository.stats(ServerId(activeId)).trackCount }.getOrNull()
            serverSubtitle = if (account != null) {
                if (count != null) "${account.displayName} · $count 首歌曲" else "${account.displayName} · 已连接"
            } else {
                "已连接服务器"
            }
        }
    }

    // AI 助手行副标题：模型接口配置状态（真实读取；未配置/已关闭如实显示）。
    var aiSubtitle by remember { mutableStateOf("大模型、推荐索引与隐私") }
    LaunchedEffect(Unit) {
        val enabled = runCatching { graph.preferences.aiEnabledValue() }.getOrDefault(true)
        val settings = runCatching { graph.preferences.aiConnectionValue() }.getOrNull()
        aiSubtitle = when {
            !enabled -> "已关闭"
            settings == null || !settings.isComplete -> "未配置模型接口"
            else -> settings.model
        }
    }

    val theme = AuralisThemeController.observe()

    SettingsPageContainer(modifier = modifier) {
        LazyColumn(modifier = Modifier.fillMaxSize()) {
            item { SettingsDetailTopBar(title = "设置", onBack = onBack) }
            item { SettingsSectionTitle("设置") }
            item {
                SettingsCategoryRow(
                    title = "服务器",
                    subtitle = serverSubtitle ?: "…",
                    icon = Icons.Filled.Dns,
                    onClick = onOpenServers,
                )
            }
            item { SettingsDivider() }
            item {
                SettingsCategoryRow(
                    title = "AI 助手",
                    subtitle = aiSubtitle,
                    icon = Icons.Filled.AutoAwesome,
                    onClick = onOpenAiSettings,
                )
                SettingsCaption("模型接口、API Key 与外发授权。")
            }
            item {
                SettingsCategoryRow(
                    title = "播放与音质",
                    subtitle = "网络音质与 ReplayGain",
                    icon = Icons.AutoMirrored.Filled.VolumeUp,
                    onClick = onOpenQuality,
                )
            }
            item { SettingsDivider() }
            item {
                SettingsCategoryRow(
                    title = "数据与备份",
                    subtitle = "本地缓存管理",
                    icon = Icons.Filled.Storage,
                    onClick = onOpenData,
                )
            }

            item { SettingsSectionTitle("外观") }
            item {
                SettingsCategoryRow(
                    title = "首页布局",
                    subtitle = "模块显示与排序",
                    icon = Icons.Filled.Tune,
                    onClick = onEditHomeLayout,
                )
            }
            item { SettingsDivider() }
            item {
                SettingsCategoryRow(
                    title = "主题",
                    subtitle = theme.name,
                    icon = Icons.Filled.Palette,
                    onClick = onOpenTheme,
                )
            }

            item { SettingsSectionTitle("关于") }
            item {
                val context = graph.appContext
                val version = remember(context) {
                    runCatching {
                        val pm = context.packageManager
                        val info = if (Build.VERSION.SDK_INT >= 33) {
                            pm.getPackageInfo(context.packageName, PackageManager.PackageInfoFlags.of(0))
                        } else {
                            @Suppress("DEPRECATION")
                            pm.getPackageInfo(context.packageName, 0)
                        }
                        val code = if (Build.VERSION.SDK_INT >= 28) {
                            info.longVersionCode
                        } else {
                            @Suppress("DEPRECATION")
                            info.versionCode.toLong()
                        }
                        "${info.versionName} ($code)"
                    }.getOrDefault("—")
                }
                SettingsValueRow(title = "版本", value = version)
            }
            item { Spacer(Modifier.height(AuralisSpacing.large)) }
        }
    }
}

/** 无图标信息行（对齐 Swift LabeledContent）。 */
@Composable
internal fun SettingsValueRow(
    title: String,
    value: String,
    modifier: Modifier = Modifier,
) {
    val colors = LocalAuralisTheme.current.colors
    Row(
        modifier = modifier
            .fillMaxWidth()
            .padding(horizontal = AuralisSpacing.large, vertical = AuralisSpacing.medium),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(title, style = MaterialTheme.typography.bodyMedium, color = colors.primaryText, modifier = Modifier.weight(1f))
        Text(value, style = MaterialTheme.typography.bodyMedium, color = colors.secondaryText)
    }
}

// ================================================================== 播放与音质

/** 对齐 Swift `PlaybackSettingsPage`：网络音质 + ReplayGain（Music Haptics 平台裁剪）。 */
@Composable
private fun QualitySettingsPage(
    graph: AuralisGraph,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = LocalAuralisTheme.current.colors
    val scope = rememberCoroutineScope()
    val prefs = graph.preferences

    val quality by prefs.streamQualityFlow.collectAsState(initial = StreamQualitySettings())
    val replayGain by prefs.replayGainFlow.collectAsState(initial = com.auralis.core.domain.ReplayGainSettings())
    var preampDrag by remember { mutableStateOf<Double?>(null) }
    val displayedPreamp = preampDrag ?: replayGain.preampDb

    fun setQuality(update: (StreamQualitySettings) -> StreamQualitySettings) {
        val next = update(quality)
        scope.launch { runCatching { prefs.setStreamQuality(next) } }
    }

    fun setReplayGain(update: (com.auralis.core.domain.ReplayGainSettings) -> com.auralis.core.domain.ReplayGainSettings) {
        val next = update(replayGain)
        scope.launch { runCatching { prefs.setReplayGain(next) } }
    }

    SettingsPageContainer(modifier = modifier) {
        LazyColumn(modifier = Modifier.fillMaxSize()) {
            item { SettingsDetailTopBar(title = "播放与音质", onBack = onBack) }

            item { SettingsSectionTitle("网络音质") }
            item {
                SettingsSwitchRow(
                    title = "Wi-Fi 优先原始音质",
                    subtitle = "Wi-Fi 下不做转码，优先服务器原始音质",
                    checked = quality.highQualityWifi,
                    onCheckedChange = { v -> setQuality { it.copy(highQualityWifi = v) } },
                )
            }
            item { SettingsDivider() }
            item {
                SettingsSwitchRow(
                    title = "蜂窝网络允许转码",
                    subtitle = "蜂窝网络下行受限时可允许服务器转码（码率上限按服务器配置）",
                    checked = quality.cellularTranscoding,
                    onCheckedChange = { v -> setQuality { it.copy(cellularTranscoding = v) } },
                )
            }

            item { SettingsSectionTitle("ReplayGain") }
            item {
                SettingsCaption("模式")
                ReplayGainMode.entries.forEach { mode ->
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clickable { setReplayGain { it.copy(mode = mode) } }
                            .padding(horizontal = AuralisSpacing.medium, vertical = AuralisSpacing.xSmall),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        RadioButton(
                            selected = replayGain.mode == mode,
                            onClick = { setReplayGain { it.copy(mode = mode) } },
                        )
                        Spacer(Modifier.width(AuralisSpacing.small))
                        Text(
                            when (mode) {
                                ReplayGainMode.Off -> "关闭"
                                ReplayGainMode.Track -> "曲目增益"
                                ReplayGainMode.Album -> "专辑增益"
                            },
                            style = MaterialTheme.typography.bodyMedium,
                            color = colors.primaryText,
                        )
                    }
                }
            }
            item { SettingsDivider() }
            item {
                SettingsCaption("前级：${String.format(Locale.US, "%+.1f", displayedPreamp)} dB")
                Slider(
                    value = displayedPreamp.toFloat(),
                    onValueChange = { preampDrag = it.toDouble() },
                    onValueChangeFinished = {
                        val v = preampDrag ?: replayGain.preampDb
                        setReplayGain { it.copy(preampDb = v) }
                        preampDrag = null
                    },
                    valueRange = -12f..12f,
                    steps = 47, // 0.5 dB 步长
                    enabled = replayGain.mode != ReplayGainMode.Off,
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = AuralisSpacing.large),
                )
                Row(
                    modifier = Modifier.fillMaxWidth().padding(horizontal = AuralisSpacing.large),
                    horizontalArrangement = Arrangement.SpaceBetween,
                ) {
                    Text("-12", style = MaterialTheme.typography.labelSmall, color = colors.secondaryText)
                    Text("+12", style = MaterialTheme.typography.labelSmall, color = colors.secondaryText)
                }
            }
            item {
                SettingsSwitchRow(
                    title = "峰值保护",
                    subtitle = "启用后按专辑/曲目峰值限制增益，避免削波",
                    checked = replayGain.peakProtection,
                    onCheckedChange = { v -> setReplayGain { it.copy(peakProtection = v) } },
                    enabled = replayGain.mode != ReplayGainMode.Off,
                )
            }
            item {
                SettingsCaption("默认关闭 ReplayGain。启用后优先使用服务器返回的真实 Track/Album Gain；缺少标签时不做普通音量归一化。")
            }
            item { Spacer(Modifier.height(AuralisSpacing.large)) }
        }
    }
}

// ================================================================== 数据与备份

/** 对齐 Swift `DataSettingsPage`：本地缓存统计 + 清理（封面/歌词带确认语义；无临时音频流缓存，如实说明）。 */
@Composable
private fun DataAndBackupPage(
    graph: AuralisGraph,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = LocalAuralisTheme.current.colors
    val scope = rememberCoroutineScope()
    val context = graph.appContext

    // 统计（真实目录/行数）。
    var metadataBytes by remember { mutableStateOf<Long?>(null) }
    var lyricCount by remember { mutableStateOf<Int?>(null) }
    var downloadedCount by remember { mutableStateOf<Int?>(null) }
    var coverCacheBytes by remember { mutableStateOf<Long?>(null) }
    var refreshing by remember { mutableStateOf(false) }

    var confirmClearArtwork by remember { mutableStateOf(false) }
    var workingLyrics by remember { mutableStateOf(false) }
    var workingArtwork by remember { mutableStateOf(false) }

    suspend fun refresh() {
        metadataBytes = dirBytes(File(context.applicationInfo.dataDir, "databases"))
            .plus(dirBytes(File(context.filesDir, "datastore")))
        lyricCount = runCatching { graph.lyricCacheCount() }.getOrNull()
        downloadedCount = runCatching {
            graph.catalogRepository.observeAll(null).first().size
        }.getOrNull()
        coverCacheBytes = runCatching {
            dirBytes(File(context.cacheDir, "image_cache"))
        }.getOrNull()
    }

    LaunchedEffect(Unit) {
        refreshing = true
        refresh()
        refreshing = false
    }

    fun clearLyrics() {
        scope.launch {
            workingLyrics = true
            // 清空 Room 歌词表（歌词按需从服务器重新加载；不删除任何其它数据）。
            runCatching { graph.clearLyricCache() }
            refresh()
            workingLyrics = false
        }
    }

    fun clearArtwork() {
        scope.launch {
            workingArtwork = true
            runCatching { clearArtworkCaches(context) }
            refresh()
            workingArtwork = false
        }
    }

    SettingsPageContainer(modifier = modifier) {
        LazyColumn(modifier = Modifier.fillMaxSize()) {
            item { SettingsDetailTopBar(title = "数据与备份", onBack = onBack) }
            item { SettingsSectionTitle("本地缓存") }
            item {
                SettingsValueRow(
                    title = "音乐库元数据",
                    value = metadataBytes?.let { formatBytes(it) } ?: "…",
                )
            }
            item { SettingsDivider() }
            item {
                SettingsValueRow(
                    title = "离线下载",
                    value = downloadedCount?.let { "$it 首" } ?: "…",
                )
            }
            item {
                SettingsCaption("离线下载的歌曲在「音乐库 → 下载」中管理，不会被缓存清理删除。")
            }
            item { SettingsDivider() }
            item {
                SettingsValueRow(
                    title = "歌词缓存",
                    value = lyricCount?.let { "$it 条" } ?: "…",
                )
                TextButton(
                    onClick = ::clearLyrics,
                    enabled = !workingLyrics && (lyricCount ?: 0) > 0,
                    modifier = Modifier.padding(start = AuralisSpacing.medium),
                ) {
                    if (workingLyrics) {
                        CircularProgressIndicator(modifier = Modifier.size(16.dp), strokeWidth = 2.dp)
                    } else {
                        Text("清理歌词缓存", color = colors.accent)
                    }
                }
            }
            item { SettingsDivider() }
            item {
                SettingsValueRow(
                    title = "封面缓存",
                    value = coverCacheBytes?.let { formatBytes(it) } ?: "…",
                )
                TextButton(
                    onClick = { confirmClearArtwork = true },
                    enabled = !workingArtwork && (coverCacheBytes ?: 0) > 0,
                    modifier = Modifier.padding(start = AuralisSpacing.medium),
                ) {
                    if (workingArtwork) {
                        CircularProgressIndicator(modifier = Modifier.size(16.dp), strokeWidth = 2.dp)
                    } else {
                        Text("清理封面缓存", color = colors.accent)
                    }
                }
            }
            item {
                SettingsCaption(
                    "App 只在本机持久化音乐库元数据（歌曲、专辑、艺术家、流派、歌单、收藏与播放记录）。" +
                        "封面与歌词按需从服务器加载，可随时清理后重新缓存。" +
                        "Android 播放为直连流式，无临时音频流缓存（与 Apple 的本地缓存模型差异已在文档记录）。"
                )
            }
            item { Spacer(Modifier.height(AuralisSpacing.large)) }
        }
    }

    if (confirmClearArtwork) {
        AlertDialog(
            onDismissRequest = { confirmClearArtwork = false },
            title = { Text("清理封面缓存？") },
            text = { Text("将删除本机已缓存的全部封面图片。今后封面只按需从服务器加载，不删除任何音乐库元数据。") },
            confirmButton = {
                TextButton(onClick = {
                    confirmClearArtwork = false
                    clearArtwork()
                }) { Text("清理", color = colors.error) }
            },
            dismissButton = {
                TextButton(onClick = { confirmClearArtwork = false }) { Text("取消") }
            },
        )
    }
}

private fun dirBytes(dir: File): Long {
    if (!dir.exists() || !dir.isDirectory) return 0L
    return dir.walkTopDown().filter { it.isFile }.sumOf { it.length() }
}

// ================================================================== 主题

/** 对齐 Swift `ThemeSettingsPage`：主题网格 + 点击即时应用（DataStore 持久化 + 进程内即时生效）。 */
@Composable
private fun ThemeSettingsPage(
    graph: AuralisGraph,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = LocalAuralisTheme.current.colors
    val scope = rememberCoroutineScope()
    val current = AuralisThemeController.observe()

    SettingsPageContainer(modifier = modifier) {
        Column(Modifier.fillMaxSize()) {
            SettingsDetailTopBar(title = "主题", onBack = onBack)
            LazyVerticalGrid(
                columns = GridCells.Adaptive(minSize = 110.dp),
                horizontalArrangement = Arrangement.spacedBy(AuralisSpacing.medium),
                verticalArrangement = Arrangement.spacedBy(AuralisSpacing.medium),
                modifier = Modifier
                    .fillMaxSize()
                    .padding(horizontal = AuralisSpacing.large, vertical = AuralisSpacing.medium),
            ) {
                items(count = BuiltInThemes.all.size, key = { BuiltInThemes.all[it].id }) { index ->
                    val theme = BuiltInThemes.all[index]
                    val selected = current.id == theme.id
                    ThemeSwatchCard(
                        theme = theme,
                        selected = selected,
                        onClick = {
                            // 立即进程内生效 + DataStore 持久化（下次冷启动恢复）。
                            AuralisThemeController.current = theme
                            scope.launch { runCatching { graph.preferences.setSelectedTheme(theme.id) } }
                        },
                    )
                }
            }
            SettingsCaption("已合并视觉结构重复的主题；旧主题选择会自动迁移到最接近的新主题。")
            Spacer(Modifier.height(AuralisSpacing.large))
        }
    }
}

@Composable
private fun ThemeSwatchCard(
    theme: com.auralis.core.designsystem.AuralisTheme,
    selected: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = LocalAuralisTheme.current.colors
    Column(
        modifier = modifier
            .clip(RoundedCornerShape(AuralisRadius.medium))
            .background(theme.colors.elevated)
            .border(
                width = if (selected) 2.dp else 0.dp,
                color = if (selected) colors.accent else androidx.compose.ui.graphics.Color.Transparent,
                shape = RoundedCornerShape(AuralisRadius.medium),
            )
            .clickable(onClick = onClick)
            .padding(AuralisSpacing.medium),
        horizontalAlignment = Alignment.Start,
    ) {
        Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            listOf(theme.colors.background, theme.colors.surface, theme.colors.elevated, theme.colors.accent).forEach { c ->
                Box(
                    modifier = Modifier
                        .size(18.dp)
                        .background(c, RoundedCornerShape(4.dp))
                        .border(0.5.dp, androidx.compose.ui.graphics.Color.White.copy(alpha = 0.25f), RoundedCornerShape(4.dp)),
                )
            }
        }
        Spacer(Modifier.height(AuralisSpacing.small))
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                theme.name,
                style = MaterialTheme.typography.bodySmall,
                fontWeight = FontWeight.SemiBold,
                color = theme.colors.primaryText,
                maxLines = 1,
                modifier = Modifier.weight(1f, fill = false),
            )
            if (selected) {
                Spacer(Modifier.width(4.dp))
                Box(
                    modifier = Modifier
                        .size(14.dp)
                        .background(colors.accent, CircleShape),
                    contentAlignment = Alignment.Center,
                ) {
                    androidx.compose.material3.Icon(
                        Icons.Filled.Check,
                        contentDescription = "已选择",
                        tint = androidx.compose.ui.graphics.Color.Black,
                        modifier = Modifier.size(10.dp),
                    )
                }
            }
        }
    }
}
