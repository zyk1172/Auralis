// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.core.playback

import com.google.common.truth.Truth.assertThat
import org.junit.Test

class PlaybackWindowIdentityTest {
    @Test
    fun `single materialized item maps media index zero to requested logical index`() {
        val materialized = PlaybackWindowIdentity.currentOnly(7)

        assertThat(materialized.first).isEqualTo(7)
        assertThat(materialized.last + 1).isEqualTo(8)
        assertThat(PlaybackWindowIdentity.logicalIndex(materialized.first, 0)).isEqualTo(7)
    }

    @Test
    fun `hydrated prefix keeps current logical identity`() {
        val targetWindowStart = 0
        val currentMediaIndexAfterPrefixInsert = 7

        assertThat(
            PlaybackWindowIdentity.logicalIndex(targetWindowStart, currentMediaIndexAfterPrefixInsert),
        ).isEqualTo(7)
    }
}
