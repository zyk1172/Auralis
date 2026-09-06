package com.auralis.core.data.prefs

import android.content.Context
import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.floatPreferencesKey
import androidx.datastore.preferences.core.intPreferencesKey
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.core.stringSetPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import com.auralis.core.domain.ReplayGainMode
import com.auralis.core.domain.ReplayGainSettings
import com.auralis.core.opensubsonic.StreamQualitySettings
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map

/**
 * 用户偏好（DataStore）。键名对齐 Apple UserDefaults：
 * `auralis.selected-theme` / `auralis.home-layout.v1` / `auralis.recent-searches` 等。
 */
private val Context.preferencesDataStore: DataStore<Preferences> by preferencesDataStore(name = "auralis_preferences")

class AuralisPreferences(private val context: Context) {

    private val store: DataStore<Preferences>
        get() = context.preferencesDataStore

    // ------------------------------------------------------------ theme

    private val selectedTheme = stringPreferencesKey("auralis.selected-theme")

    val selectedThemeFlow: Flow<String> = store.data.map { it[selectedTheme] ?: "aurora-glass" }

    suspend fun selectedThemeId(): String = selectedThemeFlow.first()

    suspend fun setSelectedTheme(id: String) {
        store.edit { it[selectedTheme] = id }
    }

    // -------------------------------------------------------- active server

    private val activeServerId = stringPreferencesKey("auralis.active-server-id")

    val activeServerIdFlow: Flow<String?> = store.data.map { it[activeServerId] }

    suspend fun activeServerIdValue(): String? = activeServerIdFlow.first()

    suspend fun setActiveServerId(id: String?) {
        store.edit { if (id == null) it.remove(activeServerId) else it[activeServerId] = id }
    }

    // ---------------------------------------------------------- home layout

    private val homeLayout = stringSetPreferencesKey("auralis.home-layout.v1")

    val homeLayoutFlow: Flow<Set<String>> = store.data.map { it[homeLayout] ?: DEFAULT_HOME_MODULES }

    suspend fun setHomeLayout(modules: Set<String>) {
        store.edit { it[homeLayout] = modules }
    }

    // ------------------------------------------------------- recent searches

    private val recentSearches = stringPreferencesKey("auralis.recent-searches")

    val recentSearchesFlow: Flow<List<String>> = store.data.map { prefs ->
        prefs[recentSearches]?.split(RECENT_SEARCH_SEPARATOR)?.filter { it.isNotBlank() }.orEmpty()
    }

    /** 最近搜索写前查重、写后截断到 [RECENT_SEARCH_LIMIT] 条。 */
    suspend fun recordSearch(query: String) {
        store.edit { prefs ->
            val current = prefs[recentSearches]?.split(RECENT_SEARCH_SEPARATOR)?.filter { it.isNotBlank() }.orEmpty()
            val updated = (listOf(query) + current.filterNot { it.equals(query, ignoreCase = true) })
                .take(RECENT_SEARCH_LIMIT)
            prefs[recentSearches] = updated.joinToString(RECENT_SEARCH_SEPARATOR)
        }
    }

    suspend fun clearSearchHistory() {
        store.edit { it.remove(recentSearches) }
    }

    // -------------------------------------------------------- stream quality

    private val wifiHighQuality = booleanPreferencesKey("auralis.wifi-high-quality")
    private val cellularTranscoding = booleanPreferencesKey("auralis.cellular-transcoding")
    private val cellularMaxBitRate = intPreferencesKey("auralis.cellular-max-bitrate")

    val streamQualityFlow: Flow<StreamQualitySettings> = store.data.map {
        StreamQualitySettings(
            highQualityWifi = it[wifiHighQuality] ?: true,
            cellularTranscoding = it[cellularTranscoding] ?: true,
            maxCellularBitRate = it[cellularMaxBitRate] ?: 320,
        )
    }

    suspend fun setStreamQuality(settings: StreamQualitySettings) {
        store.edit {
            it[wifiHighQuality] = settings.highQualityWifi
            it[cellularTranscoding] = settings.cellularTranscoding
            it[cellularMaxBitRate] = settings.maxCellularBitRate
        }
    }

    // ----------------------------------------------------------- replay gain

    private val replayGainMode = stringPreferencesKey("auralis.replay-gain-mode")
    private val replayGainPreamp = floatPreferencesKey("auralis.replay-gain-preamp")
    private val replayGainPeak = booleanPreferencesKey("auralis.replay-gain-peak-protection")

    val replayGainFlow: Flow<ReplayGainSettings> = store.data.map {
        ReplayGainSettings(
            mode = runCatching { ReplayGainMode.valueOf(it[replayGainMode] ?: "Off") }.getOrDefault(ReplayGainMode.Off),
            preampDb = (it[replayGainPreamp] ?: 0f).toDouble().coerceIn(-12.0, 12.0),
            peakProtection = it[replayGainPeak] ?: true,
        )
    }

    suspend fun setReplayGain(settings: ReplayGainSettings) {
        store.edit {
            it[replayGainMode] = settings.mode.name
            it[replayGainPreamp] = settings.preampDb.toFloat()
            it[replayGainPeak] = settings.peakProtection
        }
    }

    // ----------------------------------------------------------- play speed

    private val playbackRate = floatPreferencesKey("auralis.playback-rate")

    val playbackRateFlow: Flow<Float> = store.data.map { (it[playbackRate] ?: 1f).coerceIn(0.5f, 2f) }

    suspend fun playbackRateValue(): Float = playbackRateFlow.first()

    suspend fun setPlaybackRate(rate: Float) {
        store.edit { it[playbackRate] = rate.coerceIn(0.5f, 2f) }
    }

    companion object {
        /** 首页模块默认：6 开 3 关。 */
        const val DEFAULT_HOME_MODULES_KEY = "home-module-default"
        val DEFAULT_HOME_MODULES: Set<String> = setOf(
            "random", "recentlyPlayed", "longUnplayed", "recentlyAdded", "favoriteRandom", "downloads",
        )
        private const val RECENT_SEARCH_SEPARATOR = "\u001f"
        private const val RECENT_SEARCH_LIMIT = 10
    }
}
