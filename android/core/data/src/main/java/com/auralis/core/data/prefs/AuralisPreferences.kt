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
import com.auralis.core.domain.HomeLayoutPreference
import com.auralis.core.domain.ReplayGainMode
import com.auralis.core.domain.ReplayGainSettings
import com.auralis.core.opensubsonic.StreamQualitySettings
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put

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

    // ---------------------------------------------------- endpoint kind (内/外网)

    private val endpointKinds = stringPreferencesKey("auralis.server-endpoint-kinds.v1")
    private val kindJson = kotlinx.serialization.json.Json { ignoreUnknownKeys = true }

    /** 每服务器持久化的选中端点类型（Internal/External），冷启动恢复路由用。 */
    suspend fun endpointKind(serverId: String): String? {
        val raw = store.data.first()[endpointKinds] ?: return null
        return runCatching {
            kindJson.parseToJsonElement(raw).jsonObject[serverId]?.jsonPrimitive?.contentOrNull
        }.getOrNull()
    }

    suspend fun setEndpointKind(serverId: String, kind: String) {
        store.edit { prefs ->
            val current = prefs[endpointKinds]?.let {
                runCatching { kindJson.parseToJsonElement(it).jsonObject }.getOrNull()
            } ?: kotlinx.serialization.json.JsonObject(emptyMap())
            val updated = kotlinx.serialization.json.buildJsonObject {
                current.forEach { (k, v) -> put(k, v) }
                put(serverId, kind)
            }
            prefs[endpointKinds] = updated.toString()
        }
    }

    suspend fun clearEndpointKind(serverId: String) {
        store.edit { prefs ->
            val current = prefs[endpointKinds]?.let {
                runCatching { kindJson.parseToJsonElement(it).jsonObject }.getOrNull()
            } ?: kotlinx.serialization.json.JsonObject(emptyMap())
            if (current.isEmpty()) return@edit
            val updated = kotlinx.serialization.json.buildJsonObject {
                current.forEach { (k, v) -> if (k != serverId) put(k, v) }
            }
            if (updated.isEmpty()) prefs.remove(endpointKinds) else prefs[endpointKinds] = updated.toString()
        }
    }

    // ---------------------------------------------------------- home layout

    /** v1 用 Set<String>（存不了顺序）；发现旧 key 则迁移成 v2 有序 JSON。 */
    private val homeLayoutV1 = stringSetPreferencesKey("auralis.home-layout.v1")
    private val homeLayoutV2 = stringPreferencesKey("auralis.home-layout.v2")
    private val layoutJson = kotlinx.serialization.json.Json { ignoreUnknownKeys = true }

    val homeLayoutFlow: Flow<HomeLayoutPreference> = store.data.map { prefs ->
        val v2 = prefs[homeLayoutV2]
        if (v2 != null) {
            runCatching { layoutJson.decodeFromString<HomeLayoutPreference>(v2) }
                .getOrDefault(HomeLayoutPreference())
                .normalized()
        } else {
            val legacy = prefs[homeLayoutV1]
            if (legacy != null) migrateLegacySet(legacy).normalized() else HomeLayoutPreference().normalized()
        }
    }

    suspend fun homeLayoutValue(): HomeLayoutPreference = homeLayoutFlow.first()

    suspend fun setHomeLayout(layout: HomeLayoutPreference) {
        store.edit {
            it[homeLayoutV2] = layoutJson.encodeToString(layout.normalized())
            it.remove(homeLayoutV1)
        }
    }

    suspend fun restoreDefaultHomeLayout() = setHomeLayout(HomeLayoutPreference())

    /** 旧 Set → 有序结构：顺序按默认 registry 顺序，visible 来自旧集合。 */
    private fun migrateLegacySet(legacy: Set<String>): HomeLayoutPreference {
        val defaults = HomeLayoutPreference()
        val content = defaults.contentModules.map { it.copy(visible = it.id in legacy) }
        return defaults.copy(contentModules = content)
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
        private const val RECENT_SEARCH_SEPARATOR = "\u001f"
        private const val RECENT_SEARCH_LIMIT = 10
    }
}
