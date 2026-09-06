package com.auralis.core.common

import java.util.Locale

/**
 * 跨模块共享的展示格式化工具。
 * 从 Swift `AuralisFormatter` 等工具对齐移植；纯 JVM，无 Android 依赖。
 */
object AuralisFormat {

    /** 秒 → `m:ss` 或 `h:mm:ss`（对齐 Apple 播放时间显示）。 */
    fun duration(totalSeconds: Double): String {
        val clamped = totalSeconds.coerceAtLeast(0.0)
        val total = clamped.toLong()
        val hours = total / 3600
        val minutes = (total % 3600) / 60
        val seconds = total % 60
        return if (hours > 0) {
            String.format(Locale.ROOT, "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            String.format(Locale.ROOT, "%d:%02d", minutes, seconds)
        }
    }

    /** 秒 → `m:ss`（曲目列表行内展示，不含小时）。 */
    fun compactDuration(totalSeconds: Double): String = duration(totalSeconds)

    /** 字节数 → 人类可读（KB/MB/GB）。 */
    fun bytes(count: Long): String {
        if (count < 1024) return "$count B"
        val units = arrayOf("KB", "MB", "GB", "TB")
        var value = count.toDouble()
        var unit = -1
        while (value >= 1024 && unit < units.size - 1) {
            value /= 1024
            unit++
        }
        return String.format(Locale.ROOT, if (value >= 100) "%.0f %s" else "%.1f %s", value, units[unit])
    }

    /** epochMillis → 相对时间（"刚刚 / n 分钟前 / n 小时前 / n 天前 / 日期"）。 */
    fun relativeTime(epochMillis: Long, nowMillis: Long = System.currentTimeMillis()): String {
        val diff = nowMillis - epochMillis
        val minute = 60_000L
        val hour = 60 * minute
        val day = 24 * hour
        return when {
            diff < minute -> "刚刚"
            diff < hour -> "${diff / minute} 分钟前"
            diff < day -> "${diff / hour} 小时前"
            diff < 30 * day -> "${diff / day} 天前"
            else -> java.text.DateFormat.getDateInstance(java.text.DateFormat.MEDIUM)
                .format(java.util.Date(epochMillis))
        }
    }
}
