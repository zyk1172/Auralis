// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
package com.auralis.feature.player

import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.LooperMode

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
@LooperMode(LooperMode.Mode.PAUSED)
class LyricsLayoutTest : LyricsUiTestCases()
