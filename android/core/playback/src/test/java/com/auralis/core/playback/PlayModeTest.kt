// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.core.playback

import com.auralis.core.domain.PlayMode
import com.auralis.core.domain.RepeatMode
import com.google.common.truth.Truth.assertThat
import org.junit.Test

/** R3：播放模式枚举语义（单按钮循环顺序、repeatMode 映射、from 组合）。 */
class PlayModeTest {

    @Test
    fun `single button cycles through fixed order`() {
        assertThat(PlayMode.Sequential.next()).isEqualTo(PlayMode.Shuffle)
        assertThat(PlayMode.Shuffle.next()).isEqualTo(PlayMode.RepeatAll)
        assertThat(PlayMode.RepeatAll.next()).isEqualTo(PlayMode.RepeatOne)
        assertThat(PlayMode.RepeatOne.next()).isEqualTo(PlayMode.Sequential)
    }

    @Test
    fun `repeatMode mapping is faithful`() {
        assertThat(PlayMode.Sequential.repeatMode).isEqualTo(RepeatMode.Off)
        assertThat(PlayMode.Shuffle.repeatMode).isEqualTo(RepeatMode.Off)
        assertThat(PlayMode.RepeatAll.repeatMode).isEqualTo(RepeatMode.All)
        assertThat(PlayMode.RepeatOne.repeatMode).isEqualTo(RepeatMode.One)
    }

    @Test
    fun `shuffle flag only for Shuffle`() {
        assertThat(PlayMode.Shuffle.isShuffled).isTrue()
        assertThat(PlayMode.Sequential.isShuffled).isFalse()
        assertThat(PlayMode.RepeatAll.isShuffled).isFalse()
        assertThat(PlayMode.RepeatOne.isShuffled).isFalse()
    }

    @Test
    fun `from combines shuffle and repeat`() {
        assertThat(PlayMode.from(shuffled = true, repeat = RepeatMode.Off)).isEqualTo(PlayMode.Shuffle)
        assertThat(PlayMode.from(shuffled = false, repeat = RepeatMode.All)).isEqualTo(PlayMode.RepeatAll)
        assertThat(PlayMode.from(shuffled = false, repeat = RepeatMode.One)).isEqualTo(PlayMode.RepeatOne)
        assertThat(PlayMode.from(shuffled = false, repeat = RepeatMode.Off)).isEqualTo(PlayMode.Sequential)
        // 同时开 shuffle + repeat 时 shuffle 优先（Apple 单按钮语义：不同时放两个开关）
        assertThat(PlayMode.from(shuffled = true, repeat = RepeatMode.One)).isEqualTo(PlayMode.Shuffle)
    }
}
