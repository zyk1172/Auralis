// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.feature.assistant

import com.auralis.core.domain.Track

/**
 * R4：播放页两个「转交 AI 助手」动作的引导文案（对齐 Swift PlayerViews
 * continueWithSimilarQueue / appreciateCurrentSong 的种子消息）。
 *
 * 差异说明（如实，不冒充 Swift 全量能力）：
 * - 「由此继续播放」引用 Android 真实已注册工具 library_get_similar_songs
 *   + queue_replace（见 AssistantToolHost），语义与 Swift 一致；
 * - 「歌曲鉴赏」Swift 引用 music_appreciate（聚合外部大众评价的能力）；
 *   Android 尚未移植该工具（R6 计划），引导文案不点名不存在的工具，
 *   要求用已核验的本地数据分层输出，避免工具循环撞未注册工具报错。
 */
object GuidedSessions {

    fun playSimilarSeed(track: Track): String {
        val gid = track.globalId.serialized
        return "以当前歌曲《${track.title}》—${track.artistName}（trackID: $gid）为种子，" +
            "调用 library_get_similar_songs 查找相似歌曲，去重并优先保留高质量版本，生成约 20 首队列；" +
            "最后只调用一次 queue_replace 替换当前播放队列并开始播放。不要只输出文字建议。"
    }

    fun appreciateSeed(track: Track): String {
        val gid = track.globalId.serialized
        return "请专业鉴赏《${track.title}》—${track.artistName}（trackID: $gid），" +
            "按应用规定的鉴赏格式输出，区分【已核验事实】【专业听感】【大众评价】：" +
            "可调用 getTrack / lyrics_get 等工具核验元数据与歌词；" +
            "没有可核验的外部大众评价数据时，大众评价段必须写「暂无可核验的大众评价数据。」"
    }
}
