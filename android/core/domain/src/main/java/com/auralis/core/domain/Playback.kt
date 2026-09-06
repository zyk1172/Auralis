package com.auralis.core.domain

import kotlinx.serialization.Serializable
import kotlin.math.log10
import kotlin.math.pow

@Serializable
sealed interface PlaybackError {
    @Serializable
    data object NetworkUnavailable : PlaybackError

    @Serializable
    data class UnsupportedFormat(val detail: String) : PlaybackError

    @Serializable
    data object AuthorizationFailed : PlaybackError

    @Serializable
    data class EngineFailure(val detail: String) : PlaybackError
}

/**
 * 播放状态。Apple 端 `PlaybackState` 没有 `ended` 态——自然播完会走
 * `trackEndedHandler`，由上层决定下一首/单曲循环/停在队尾。
 * UI 不能只有 `isPlaying: Boolean`。
 */
@Serializable
sealed interface PlaybackState {
    @Serializable
    data object Idle : PlaybackState

    @Serializable
    data object Preparing : PlaybackState

    @Serializable
    data object Buffering : PlaybackState

    @Serializable
    data object Playing : PlaybackState

    @Serializable
    data object Paused : PlaybackState

    @Serializable
    data object Stalled : PlaybackState

    @Serializable
    data class Failed(val error: PlaybackError) : PlaybackState

    val isActive: Boolean
        get() = this is Playing || this is Buffering || this is Stalled || this is Preparing
}

@Serializable
enum class RepeatMode { Off, All, One }

/**
 * 完整播放器只有一个按钮循环切换播放模式，语义顺序固定：
 * 顺序 → 随机 → 列表循环 → 单曲循环 → 顺序。
 * 不允许同时放 Shuffle / Repeat / RepeatOne 三个按钮。
 */
@Serializable
enum class PlayMode {
    Sequential,
    Shuffle,
    RepeatAll,
    RepeatOne,
    ;

    val isShuffled: Boolean get() = this == Shuffle

    val repeatMode: RepeatMode
        get() = when (this) {
            RepeatAll -> RepeatMode.All
            RepeatOne -> RepeatMode.One
            else -> RepeatMode.Off
        }

    fun next(): PlayMode = when (this) {
        Sequential -> Shuffle
        Shuffle -> RepeatAll
        RepeatAll -> RepeatOne
        RepeatOne -> Sequential
    }

    companion object {
        fun from(shuffled: Boolean, repeat: RepeatMode): PlayMode = when {
            shuffled -> Shuffle
            repeat == RepeatMode.All -> RepeatAll
            repeat == RepeatMode.One -> RepeatOne
            else -> Sequential
        }
    }
}

@Serializable
enum class ReplayGainMode { Off, Track, Album }

/** 前级范围 -12...+12 dB，与 Apple `ReplayGainSettings` 一致。 */
@Serializable
data class ReplayGainSettings(
    val mode: ReplayGainMode = ReplayGainMode.Off,
    val preampDb: Double = 0.0,
    val peakProtection: Boolean = true,
) {
    init {
        require(preampDb in -12.0..12.0) { "preampDb must be within -12..12" }
    }
}

@Serializable
enum class ReplayGainSource { Disabled, Missing, Track, Album, Fallback }

@Serializable
data class ReplayGainAdjustment(
    val source: ReplayGainSource,
    val requestedGainDb: Double,
    val appliedGainDb: Double,
    val linearMultiplier: Float,
    val peakLimited: Boolean,
) {
    companion object {
        val Disabled = ReplayGainAdjustment(ReplayGainSource.Disabled, 0.0, 0.0, 1f, false)
    }
}

/**
 * ReplayGain 纯计算，逐行移植自 `PlaybackEngine/ReplayGain.swift:44-106`。
 *
 * 语义要点：
 * 1. `off` 直接 disabled，不计算；
 * 2. requestedDb 先钳到 [-60, +24]；
 * 3. multiplier = 10^(db/20)，appliedDb = 20*log10(multiplier)；
 * 4. peak protection：maximum = 1/peak，超过则钳位并标记 peakLimited；
 * 5. 直接 gain 缺失时退回 fallbackGainDb，source 记 Fallback。
 *
 * 注意：ReplayGain 与用户音量是两件事，不得覆盖用户 volume preference。
 */
object ReplayGainCalculator {
    fun adjustment(
        metadata: ReplayGainMetadata?,
        settings: ReplayGainSettings,
    ): ReplayGainAdjustment {
        if (settings.mode == ReplayGainMode.Off) return ReplayGainAdjustment.Disabled
        if (metadata == null) return missing()

        val direct: Double?
        val peak: Double?
        val sourceWhenDirect: ReplayGainSource
        when (settings.mode) {
            ReplayGainMode.Off -> return ReplayGainAdjustment.Disabled
            ReplayGainMode.Track -> {
                direct = finite(metadata.trackGainDb)
                peak = validPeak(metadata.trackPeak)
                sourceWhenDirect = ReplayGainSource.Track
            }

            ReplayGainMode.Album -> {
                direct = finite(metadata.albumGainDb)
                peak = validPeak(metadata.albumPeak)
                sourceWhenDirect = ReplayGainSource.Album
            }
        }

        val fallback = finite(metadata.fallbackGainDb)
        val contentGain = direct ?: fallback ?: return missing()
        val source = if (direct == null) ReplayGainSource.Fallback else sourceWhenDirect
        val baseGain = finite(metadata.baseGainDb) ?: 0.0

        val requestedDb = (contentGain + baseGain + settings.preampDb).coerceIn(-60.0, 24.0)
        var multiplier = 10.0.pow(requestedDb / 20.0)
        var peakLimited = false

        if (settings.peakProtection && peak != null) {
            val maximum = 1.0 / peak
            if (multiplier > maximum) {
                multiplier = maximum
                peakLimited = true
            }
        }

        if (!multiplier.isFinite() || multiplier <= 0.0) return missing()
        val appliedDb = 20.0 * log10(multiplier)
        return ReplayGainAdjustment(
            source = source,
            requestedGainDb = requestedDb,
            appliedGainDb = appliedDb,
            linearMultiplier = multiplier.toFloat(),
            peakLimited = peakLimited,
        )
    }

    private fun missing() = ReplayGainAdjustment(
        source = ReplayGainSource.Missing,
        requestedGainDb = 0.0,
        appliedGainDb = 0.0,
        linearMultiplier = 1f,
        peakLimited = false,
    )

    private fun finite(value: Double?): Double? = value?.takeIf { it.isFinite() }
    private fun validPeak(value: Double?): Double? = finite(value)?.takeIf { it > 0.0 }
}
