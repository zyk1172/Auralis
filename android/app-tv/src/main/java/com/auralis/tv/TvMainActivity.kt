package com.auralis.tv

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.auralis.core.designsystem.AuralisTheme
import com.auralis.core.designsystem.AuralisThemeController
import com.auralis.core.designsystem.LocalAuralisTheme

/** TV 壳 Activity。TV 页面在 feature 层接入后替换占位。 */
class TvMainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        setContent {
            AuralisTheme(theme = AuralisThemeController.observe()) {
                TvPlaceholder()
            }
        }
    }
}

@androidx.compose.runtime.Composable
private fun TvPlaceholder() {
    val colors = LocalAuralisTheme.current.colors
    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(colors.background)
            .padding(32.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text(
            text = "Auralis TV",
            style = MaterialTheme.typography.headlineMedium,
            color = colors.primaryText,
        )
    }
}
