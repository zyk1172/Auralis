package com.auralis.core.opensubsonic

import kotlinx.serialization.Serializable

/**
 * 流质量决策结果。
 * [maxBitRate] 为 [NO_BITRATE_LIMIT] 且 [format] 为空 → 原始质量，不加转码参数。
 */
@Serializable
data class StreamQualityDecision(
    val maxBitRate: Int = NO_BITRATE_LIMIT,
    val format: String? = null,
) {
    companion object {
        const val NO_BITRATE_LIMIT = 0

        /** 原始质量：不带 maxBitRate / format。 */
        val Raw = StreamQualityDecision()

        /** 蜂窝转码：MP3，最高 320kbps。 */
        val CellularTranscoded = StreamQualityDecision(maxBitRate = 320, format = "mp3")
    }
}

@Serializable
data class StreamQualitySettings(
    /** Wi-Fi 下优先原始音质。 */
    val highQualityWifi: Boolean = true,
    /** 蜂窝网络允许转码（开启后蜂窝走 MP3 320kbps）。 */
    val cellularTranscoding: Boolean = true,
    val maxCellularBitRate: Int = 320,
)

enum class NetworkKind { Wifi, Cellular, Other }

/**
 * 流质量策略。对齐 Apple `StreamQualityPolicy`：
 * - Wi-Fi + 高音质开关 → 原始质量；
 * - 蜂窝 + 允许转码 → MP3、最高 320kbps；
 * - 其它情况 → 原始质量。
 *
 * Android 用 `ConnectivityManager` / `NetworkCapabilities` 判断 [NetworkKind]。
 */
object StreamQualityPolicy {
    fun decide(settings: StreamQualitySettings, network: NetworkKind): StreamQualityDecision = when (network) {
        NetworkKind.Wifi -> if (settings.highQualityWifi) {
            StreamQualityDecision.Raw
        } else {
            StreamQualityDecision(maxBitRate = settings.maxCellularBitRate, format = "mp3")
        }

        NetworkKind.Cellular -> if (settings.cellularTranscoding) {
            StreamQualityDecision(
                maxBitRate = settings.maxCellularBitRate.coerceAtMost(320),
                format = "mp3",
            )
        } else {
            StreamQualityDecision.Raw
        }

        NetworkKind.Other -> StreamQualityDecision.Raw
    }
}
