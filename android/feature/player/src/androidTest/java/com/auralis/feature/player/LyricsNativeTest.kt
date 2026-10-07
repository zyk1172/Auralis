// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
package com.auralis.feature.player

import android.graphics.Bitmap
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.Text
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onRoot
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.auralis.core.designsystem.AuralisTheme
import com.google.common.truth.Truth.assertThat
import java.io.File
import org.junit.Test
import org.junit.runner.RunWith

/** Exercises the same production lyric components on an Android device, including native shaping. */
@RunWith(AndroidJUnit4::class)
class LyricsNativeTest : LyricsUiTestCases() {
    override fun recordFrame(name: String) {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        File(context.getExternalFilesDir(null), "$name.png").outputStream().use {
            compose.onRoot().captureToImage().asAndroidBitmap().compress(Bitmap.CompressFormat.PNG, 100, it)
        }
    }

    @Test
    fun landscapeCoverFitsWithMarginsAndNoOverlap() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        instrumentation.uiAutomation.setRotation(android.app.UiAutomation.ROTATION_FREEZE_90)
        try {
            compose.setContent {
                AuralisTheme(reduceMotion = true) {
                    NowPlayingChromeLayout(
                        page = PlayerTab.Lyrics,
                        chromeHidden = false,
                        onClose = {},
                        artwork = { Box(Modifier.fillMaxSize().background(Color(0xFF547B98))) },
                        pageContent = { Text("Lyrics", Modifier.testTag("nativeLyrics")) },
                        pageFooter = { Text("Track identity") },
                        controls = { _, _ -> },
                    )
                }
            }
            compose.waitUntil(timeoutMillis = 15_000) {
                compose.onAllNodesWithTag("player.landscape").fetchSemanticsNodes().isNotEmpty()
            }
            val artwork = compose.onNodeWithTag("player.artwork").fetchSemanticsNode().boundsInRoot
            val lyrics = compose.onNodeWithTag("nativeLyrics").fetchSemanticsNode().boundsInRoot
            val root = compose.onRoot().fetchSemanticsNode().boundsInRoot
            assertThat(artwork.width).isWithin(1f).of(artwork.height)
            assertThat(artwork.left).isGreaterThan(root.left)
            assertThat(artwork.top).isGreaterThan(root.top)
            assertThat(artwork.bottom).isLessThan(root.bottom)
            assertThat(artwork.right).isLessThan(lyrics.left)
            val output = File(instrumentation.targetContext.getExternalFilesDir(null), "player-landscape.png")
            output.outputStream().use {
                compose.onRoot().captureToImage().asAndroidBitmap().compress(Bitmap.CompressFormat.PNG, 100, it)
            }
        } finally {
            instrumentation.uiAutomation.setRotation(android.app.UiAutomation.ROTATION_UNFREEZE)
        }
    }
}
