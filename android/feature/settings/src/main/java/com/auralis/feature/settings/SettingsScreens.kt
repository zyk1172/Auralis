// SPDX-License-Identifier: GPL-3.0-only
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
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
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
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.auralis.core.data.graph.AuralisGraph
import com.auralis.core.designsystem.AuralisRadius
import com.auralis.core.designsystem.AuralisSpacing
import com.auralis.core.designsystem.AuralisThemeController
import com.auralis.core.designsystem.BuiltInThemes
import com.auralis.core.designsystem.LocalAuralisTheme
import com.auralis.core.designsystem.R as AuralisR
import com.auralis.core.domain.ReplayGainMode
import com.auralis.core.domain.RecommendationIndexUiState
import com.auralis.core.domain.ServerId
import com.auralis.core.image.clearArtworkCaches
import com.auralis.core.opensubsonic.StreamQualitySettings
import java.io.File
import java.util.Locale
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.yield

/**
 * 设置（对齐 Swift `SettingsView` 主表 + `SettingsDetailPages` 子页）。
 *
 * 根列表的滚动位置和最后进入的分类入口都是 saveable state。这样电视遥控器从任何子页
 * 返回时会回到刚才的入口，不会每次重新从列表第一项开始；移动端也自然保留列表位置。
 */
@Composable
fun SettingsScreen(
    graph: AuralisGraph,
    onBack: () -> Unit,
    onOpenServers: () -> Unit,
    onEditHomeLayout: () -> Unit,
    onOpenAiSettings: () -> Unit,
    recommendationIndexState: RecommendationIndexUiState = RecommendationIndexUiState(),
    onStartRecommendationIndex: () -> Unit = {},
    onCancelRecommendationIndex: () -> Unit = {},
    onRefreshRecommendationIndex: () -> Unit = {},
    modifier: Modifier = Modifier,
) {
    var pageOrdinal by rememberSaveable { mutableIntStateOf(NO_PAGE) }
    var returnFocusItem by rememberSaveable { mutableIntStateOf(NO_FOCUS_ITEM) }
    val rootListState = rememberLazyListState()
    val page = SettingsPage.entries.getOrNull(pageOrdinal)

    fun rememberEntry(itemIndex: Int) {
        returnFocusItem = itemIndex
    }

    BackHandler(enabled = page != null) { pageOrdinal = NO_PAGE }

    when (page) {
        null -> SettingsRootPage(
            graph = graph,
            onBack = onBack,
            onOpenServers = {
                rememberEntry(ROOT_ITEM_SERVERS)
                onOpenServers()
            },
            onEditHomeLayout = {
                rememberEntry(ROOT_ITEM_HOME_LAYOUT)
                onEditHomeLayout()
            },
            onOpenAiSettings = {
                rememberEntry(ROOT_ITEM_AI)
                onOpenAiSettings()
            },
            recommendationIndexState = recommendationIndexState,
            onStartRecommendationIndex = onStartRecommendationIndex,
            onCancelRecommendationIndex = onCancelRecommendationIndex,
            onRefreshRecommendationIndex = onRefreshRecommendationIndex,
            onOpenQuality = {
                rememberEntry(ROOT_ITEM_QUALITY)
                pageOrdinal = SettingsPage.Quality.ordinal
            },
            onOpenData = {
                rememberEntry(ROOT_ITEM_DATA)
                pageOrdinal = SettingsPage.Data.ordinal
            },
            onOpenTheme = {
                rememberEntry(ROOT_ITEM_THEME)
                pageOrdinal = SettingsPage.Theme.ordinal
            },
            listState = rootListState,
            restoreFocusItem = returnFocusItem,
            modifier = modifier,
        )

        SettingsPage.Quality -> QualitySettingsPage(graph = graph, onBack = { pageOrdinal = NO_PAGE }, modifier = modifier)
        SettingsPage.Data -> DataAndBackupPage(graph = graph, onBack = { pageOrdinal = NO_PAGE }, modifier = modifier)
        SettingsPage.Theme -> ThemeSettingsPage(graph = graph, onBack = { pageOrdinal = NO_PAGE }, modifier = modifier)
    }
}

private enum class SettingsPage { Quality, Data, Theme }

private const val NO_PAGE = -1
private const val NO_FOCUS_ITEM = -1
private const val ROOT_ITEM_SERVERS = 2
private const val ROOT_ITEM_AI = 4
private const val ROOT_ITEM_QUALITY = 6
private const val ROOT_ITEM_DATA = 8
private const val ROOT_ITEM_HOME_LAYOUT = 10
private const val ROOT_ITEM_THEME = 12

@Composable
private fun RecommendationIndexSettingsCard(
    state: RecommendationIndexUiState,
    onStart: () -> Unit,
    onCancel: () -> Unit,
    onRefresh: () -> Unit,
) {
    val colors = LocalAuralisTheme.current.colors
    val error = state.error
    val status = when {
        state.isRunning -> stringResource(
            R.string.settings_recommendation_index_running_format,
            state.indexedTracks,
            state.totalTracks,
        )
        error != null -> stringResource(R.string.settings_recommendation_index_error_format, error)
        state.totalTracks == 0 -> stringResource(R.string.settings_recommendation_index_no_tracks)
        state.pendingTracks > 0 -> stringResource(
            R.string.settings_recommendation_index_pending_format,
            state.pendingTracks,
            state.totalTracks,
        )
        else -> stringResource(R.string.settings_recommendation_index_complete_format, state.indexedTracks)
    }
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = AuralisSpacing.large, vertical = AuralisSpacing.small)
            .background(colors.surface, RoundedCornerShape(12.dp))
            .padding(horizontal = AuralisSpacing.medium, vertical = AuralisSpacing.small),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text(
                    stringResource(R.string.settings_recommendation_index_title),
                    style = MaterialTheme.typography.bodyLarge,
                    color = colors.primaryText,
                    fontWeight = FontWeight.Medium,
                )
                Text(status, style = MaterialTheme.typography.bodySmall, color = colors.secondaryText)
            }
            when {
                state.isRunning -> TextButton(onClick = onCancel) { Text(stringResource(AuralisR.string.cancel)) }
                state.pendingTracks > 0 || state.error != null -> TextButton(onClick = onStart) {
                    Text(stringResource(R.string.settings_recommendation_index_start))
                }
                else -> TextButton(onClick = onRefresh) {
                    Text(stringResource(R.string.settings_recommendation_index_refresh))
                }
            }
        }
        if (state.isRunning && state.totalTracks > 0) {
            androidx.compose.material3.LinearProgressIndicator(
                progress = { (state.indexedTracks.toFloat() / state.totalTracks).coerceIn(0f, 1f) },
                modifier = Modifier.fillMaxWidth(),
                color = colors.accent,
            )
        }
    }
}

@Composable
private fun SettingsRootPage(
    graph: AuralisGraph,
    onBack: () -> Unit,
    onOpenServers: () -> Unit,
    onEditHomeLayout: () -> Unit,
    onOpenAiSettings: () -> Unit,
    recommendationIndexState: RecommendationIndexUiState,
    onStartRecommendationIndex: () -> Unit,
    onCancelRecommendationIndex: () -> Unit,
    onRefreshRecommendationIndex: () -> Unit,
    onOpenQuality: () -> Unit,
    onOpenData: () -> Unit,
    onOpenTheme: () -> Unit,
    listState: LazyListState,
    restoreFocusItem: Int,
    modifier: Modifier = Modifier,
) {
    val colors = LocalAuralisTheme.current.colors
    val scope = rememberCoroutineScope()
    val context = LocalContext.current.applicationContext
    val focusRequesters = remember {
        mapOf(
            ROOT_ITEM_SERVERS to FocusRequester(),
            ROOT_ITEM_AI to FocusRequester(),
            ROOT_ITEM_QUALITY to FocusRequester(),
            ROOT_ITEM_DATA to FocusRequester(),
            ROOT_ITEM_HOME_LAYOUT to FocusRequester(),
            ROOT_ITEM_THEME to FocusRequester(),
        )
    }

    LaunchedEffect(restoreFocusItem) {
        val requester = focusRequesters[restoreFocusItem] ?: return@LaunchedEffect
        listState.scrollToItem((restoreFocusItem - 1).coerceAtLeast(0))
        yield()
        runCatching { requester.requestFocus() }
    }

    var serverSubtitle by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(Unit) {
        serverSubtitle = null
        val servers = runCatching { graph.catalogRepository.servers() }.getOrDefault(emptyList())
        val activeId = runCatching { graph.preferences.activeServerIdValue() }.getOrNull()
        if (activeId == null) {
            serverSubtitle = context.getString(R.string.settings_server_connect_hint)
        } else {
            val account = servers.firstOrNull { it.id.value == activeId }
            val count = runCatching { graph.catalogRepository.stats(ServerId(activeId)).trackCount }.getOrNull()
            serverSubtitle = if (account != null) {
                if (count != null) {
                    context.getString(R.string.settings_server_sync_format, account.displayName, count)
                } else {
                    context.getString(R.string.settings_server_connected_format, account.displayName)
                }
            } else {
                context.getString(R.string.settings_server_connected)
            }
        }
    }

    var aiSubtitle by remember { mutableStateOf(context.getString(R.string.settings_ai_subtitle_default)) }
    LaunchedEffect(Unit) {
        val enabled = runCatching { graph.preferences.aiEnabledValue() }.getOrDefault(true)
        val settings = runCatching { graph.preferences.aiConnectionValue() }.getOrNull()
        aiSubtitle = when {
            !enabled -> context.getString(R.string.settings_ai_off)
            settings == null || !settings.isComplete -> context.getString(R.string.settings_ai_not_configured)
            else -> settings.model
        }
    }

    val theme = AuralisThemeController.observe()

    SettingsPageContainer(modifier = modifier) {
        LazyColumn(state = listState, modifier = Modifier.fillMaxSize()) {
            item { SettingsDetailTopBar(title = stringResource(AuralisR.string.settings), onBack = onBack) }
            item { SettingsSectionTitle(stringResource(AuralisR.string.settings)) }
            item {
                SettingsCategoryRow(
                    title = stringResource(AuralisR.string.servers),
                    subtitle = serverSubtitle ?: "…",
                    icon = Icons.Filled.Dns,
                    onClick = onOpenServers,
                    modifier = Modifier.focusRequester(focusRequesters.getValue(ROOT_ITEM_SERVERS)),
                )
            }
            item { SettingsDivider() }
            item {
                SettingsCategoryRow(
                    title = stringResource(R.string.settings_ai_title),
                    subtitle = aiSubtitle,
                    icon = Icons.Filled.AutoAwesome,
                    onClick = onOpenAiSettings,
                    modifier = Modifier.focusRequester(focusRequesters.getValue(ROOT_ITEM_AI)),
                )
                SettingsCaption(stringResource(R.string.settings_ai_caption))
            }
            item {
                RecommendationIndexSettingsCard(
                    state = recommendationIndexState,
                    onStart = onStartRecommendationIndex,
                    onCancel = onCancelRecommendationIndex,
                    onRefresh = onRefreshRecommendationIndex,
                )
            }
            item {
                SettingsCategoryRow(
                    title = stringResource(R.string.settings_quality_title),
                    subtitle = stringResource(R.string.settings_quality_subtitle),
                    icon = Icons.AutoMirrored.Filled.VolumeUp,
                    onClick = onOpenQuality,
                    modifier = Modifier.focusRequester(focusRequesters.getValue(ROOT_ITEM_QUALITY)),
                )
            }
            item { SettingsDivider() }
            item {
                SettingsCategoryRow(
                    title = stringResource(R.string.settings_data_title),
                    subtitle = stringResource(R.string.settings_data_subtitle),
                    icon = Icons.Filled.Storage,
                    onClick = onOpenData,
                    modifier = Modifier.focusRequester(focusRequesters.getValue(ROOT_ITEM_DATA)),
                )
            }

            item { SettingsSectionTitle(stringResource(R.string.settings_appearance)) }
            item {
                SettingsCategoryRow(
                    title = stringResource(R.string.settings_home_layout),
                    subtitle = stringResource(R.string.settings_home_layout_subtitle),
                    icon = Icons.Filled.Tune,
                    onClick = onEditHomeLayout,
                    modifier = Modifier.focusRequester(focusRequesters.getValue(ROOT_ITEM_HOME_LAYOUT)),
                )
            }
            item { SettingsDivider() }
            item {
                SettingsCategoryRow(
                    title = stringResource(R.string.settings_theme_title),
                    subtitle = stringResource(theme.nameRes),
                    icon = Icons.Filled.Palette,
                    onClick = onOpenTheme,
                    modifier = Modifier.focusRequester(focusRequesters.getValue(ROOT_ITEM_THEME)),
                )
            }

            item { SettingsSectionTitle(stringResource(R.string.settings_about)) }
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
                SettingsValueRow(title = stringResource(R.string.settings_version), value = version)
            }
            item { Spacer(Modifier.height(AuralisSpacing.large)) }
        }
    }
}

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
            item { SettingsDetailTopBar(title = stringResource(R.string.settings_quality_title), onBack = onBack) }

            item { SettingsSectionTitle(stringResource(R.string.settings_network_quality)) }
            item {
                SettingsSwitchRow(
                    title = stringResource(R.string.settings_wifi_original),
                    subtitle = stringResource(R.string.settings_wifi_original_note),
                    checked = quality.highQualityWifi,
                    onCheckedChange = { v -> setQuality { it.copy(highQualityWifi = v) } },
                )
            }
            item { SettingsDivider() }
            item {
                SettingsSwitchRow(
                    title = stringResource(R.string.settings_cellular_transcode),
                    subtitle = stringResource(R.string.settings_cellular_transcode_note),
                    checked = quality.cellularTranscoding,
                    onCheckedChange = { v -> setQuality { it.copy(cellularTranscoding = v) } },
                )
            }

            item { SettingsSectionTitle("ReplayGain") }
            item {
                SettingsCaption(stringResource(R.string.settings_replaygain_mode))
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
                            stringResource(
                                when (mode) {
                                    ReplayGainMode.Off -> R.string.settings_replaygain_off
                                    ReplayGainMode.Track -> R.string.settings_replaygain_track
                                    ReplayGainMode.Album -> R.string.settings_replaygain_album
                                },
                            ),
                            style = MaterialTheme.typography.bodyMedium,
                            color = colors.primaryText,
                        )
                    }
                }
            }
            item { SettingsDivider() }
            item {
                SettingsCaption(stringResource(R.string.settings_preamp_format, String.format(Locale.US, "%+.1f", displayedPreamp)))
                Slider(
                    value = displayedPreamp.toFloat(),
                    onValueChange = { preampDrag = it.toDouble() },
                    onValueChangeFinished = {
                        val v = preampDrag ?: replayGain.preampDb
                        setReplayGain { it.copy(preampDb = v) }
                        preampDrag = null
                    },
                    valueRange = -12f..12f,
                    steps = 47,
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
                    title = stringResource(R.string.settings_peak_protection),
                    subtitle = stringResource(R.string.settings_peak_protection_note),
                    checked = replayGain.peakProtection,
                    onCheckedChange = { v -> setReplayGain { it.copy(peakProtection = v) } },
                    enabled = replayGain.mode != ReplayGainMode.Off,
                )
            }
            item { SettingsCaption(stringResource(R.string.settings_replaygain_default_note)) }
            item { Spacer(Modifier.height(AuralisSpacing.large)) }
        }
    }
}

@Composable
private fun DataAndBackupPage(
    graph: AuralisGraph,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = LocalAuralisTheme.current.colors
    val scope = rememberCoroutineScope()
    val context = graph.appContext

    var metadataBytes by remember { mutableStateOf<Long?>(null) }
    var lyricCount by remember { mutableStateOf<Int?>(null) }
    var downloadedCount by remember { mutableStateOf<Int?>(null) }
    var coverCacheBytes by remember { mutableStateOf<Long?>(null) }
    var confirmClearArtwork by remember { mutableStateOf(false) }
    var workingLyrics by remember { mutableStateOf(false) }
    var workingArtwork by remember { mutableStateOf(false) }

    suspend fun refresh() {
        metadataBytes = dirBytes(File(context.applicationInfo.dataDir, "databases"))
            .plus(dirBytes(File(context.filesDir, "datastore")))
        lyricCount = runCatching { graph.lyricCacheCount() }.getOrNull()
        downloadedCount = runCatching { graph.catalogRepository.observeAll(null).first().size }.getOrNull()
        coverCacheBytes = runCatching { dirBytes(File(context.cacheDir, "image_cache")) }.getOrNull()
    }

    LaunchedEffect(Unit) { refresh() }

    fun clearLyrics() {
        scope.launch {
            workingLyrics = true
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
            item { SettingsDetailTopBar(title = stringResource(R.string.settings_data_title), onBack = onBack) }
            item { SettingsSectionTitle(stringResource(R.string.settings_local_cache)) }
            item {
                SettingsValueRow(
                    title = stringResource(R.string.settings_metadata_title),
                    value = metadataBytes?.let { formatBytes(it) } ?: "…",
                )
            }
            item { SettingsDivider() }
            item {
                SettingsValueRow(
                    title = stringResource(R.string.settings_downloads_title),
                    value = downloadedCount?.let { stringResource(AuralisR.string.count_songs, it) } ?: "…",
                )
            }
            item { SettingsCaption(stringResource(R.string.settings_downloads_note)) }
            item { SettingsDivider() }
            item {
                SettingsValueRow(
                    title = stringResource(R.string.settings_lyric_cache_title),
                    value = lyricCount?.let { stringResource(R.string.settings_count_lyrics_format, it) } ?: "…",
                )
                TextButton(
                    onClick = ::clearLyrics,
                    enabled = !workingLyrics && (lyricCount ?: 0) > 0,
                    modifier = Modifier.padding(start = AuralisSpacing.medium),
                ) {
                    if (workingLyrics) CircularProgressIndicator(modifier = Modifier.size(16.dp), strokeWidth = 2.dp)
                    else Text(stringResource(R.string.settings_clear_lyrics), color = colors.accent)
                }
            }
            item { SettingsDivider() }
            item {
                SettingsValueRow(
                    title = stringResource(R.string.settings_cover_cache_title),
                    value = coverCacheBytes?.let { formatBytes(it) } ?: "…",
                )
                TextButton(
                    onClick = { confirmClearArtwork = true },
                    enabled = !workingArtwork && (coverCacheBytes ?: 0) > 0,
                    modifier = Modifier.padding(start = AuralisSpacing.medium),
                ) {
                    if (workingArtwork) CircularProgressIndicator(modifier = Modifier.size(16.dp), strokeWidth = 2.dp)
                    else Text(stringResource(R.string.settings_clear_cover), color = colors.accent)
                }
            }
            item { SettingsCaption(stringResource(R.string.settings_data_note)) }
            item { Spacer(Modifier.height(AuralisSpacing.large)) }
        }
    }

    if (confirmClearArtwork) {
        AlertDialog(
            onDismissRequest = { confirmClearArtwork = false },
            title = { Text(stringResource(R.string.settings_clear_cover_confirm)) },
            text = { Text(stringResource(R.string.settings_clear_cover_message)) },
            confirmButton = {
                TextButton(onClick = {
                    confirmClearArtwork = false
                    clearArtwork()
                }) { Text(stringResource(R.string.settings_clear), color = colors.error) }
            },
            dismissButton = {
                TextButton(onClick = { confirmClearArtwork = false }) { Text(stringResource(AuralisR.string.cancel)) }
            },
        )
    }
}

private fun dirBytes(dir: File): Long {
    if (!dir.exists() || !dir.isDirectory) return 0L
    return dir.walkTopDown().filter { it.isFile }.sumOf { it.length() }
}

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
            SettingsDetailTopBar(title = stringResource(R.string.settings_theme_title), onBack = onBack)
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
                            AuralisThemeController.current = theme
                            scope.launch { runCatching { graph.preferences.setSelectedTheme(theme.id) } }
                        },
                    )
                }
            }
            SettingsCaption(stringResource(R.string.settings_theme_note))
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
                stringResource(theme.nameRes),
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
                        contentDescription = stringResource(R.string.settings_theme_selected),
                        tint = androidx.compose.ui.graphics.Color.Black,
                        modifier = Modifier.size(10.dp),
                    )
                }
            }
        }
    }
}
