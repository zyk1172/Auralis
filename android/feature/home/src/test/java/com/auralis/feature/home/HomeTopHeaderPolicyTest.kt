// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.feature.home

import com.google.common.truth.Truth.assertThat
import org.junit.Test

class HomeTopHeaderPolicyTest {
    @Test
    fun `only upward scroll moves title and clips at one header height`() {
        assertThat(HomeTopHeaderPolicy.offset(0, -20f, 60f)).isEqualTo(0f)
        assertThat(HomeTopHeaderPolicy.offset(0, 30f, 60f)).isEqualTo(30f)
        assertThat(HomeTopHeaderPolicy.offset(0, 100f, 60f)).isEqualTo(60f)
        assertThat(HomeTopHeaderPolicy.offset(1, 0f, 60f)).isEqualTo(60f)
    }
}
