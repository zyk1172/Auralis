// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.feature.player

import com.auralis.core.domain.Track

/**
 * 播放页三点菜单里「需要转交 AI 助手」的动作（R4，对齐 Swift PlayerViews：
 * 由此继续播放 → musicDiscovery 会话；歌曲鉴赏 → musicAppreciation 会话）。
 *
 * 播放模块不依赖 assistant 模块：壳层（MobileShell）把动作映射成
 * 「关播放页 → 切 Assistant → 引导新会话」，feature:player 只声明意图。
 */
enum class PlayerTrackAction {
    /** 以当前曲为种子，生成相似歌曲队列并替换播放（Swift continueWithSimilarQueue）。 */
    PlaySimilar,

    /** 进入干净新会话鉴赏当前歌曲（Swift appreciateCurrentSong）。 */
    Appreciate,
}

/** 触发回调：由壳层决定如何转交助理。传 null 表示不提供（如 TV 无助理入口时隐藏菜单项）。 */
typealias PlayerTrackActionHandler = (track: Track, action: PlayerTrackAction) -> Unit
