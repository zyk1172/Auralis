package com.auralis.mobile

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.auralis.core.designsystem.AuralisTheme
import com.auralis.core.designsystem.AuralisThemeController
import com.auralis.core.designsystem.LocalAuralisTheme

/**
 * 单一 Activity。底部 Dock / 页面切换在 feature 层接入后替换占位内容。
 */
class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        setContent {
            AuralisTheme(theme = AuralisThemeController.observe()) {
                MobileHomePlaceholder()
            }
        }
    }
}

@Composable
private fun MobileHomePlaceholder() {
    val colors = LocalAuralisTheme.current.colors
    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(colors.background)
            .padding(24.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text(
            text = "Auralis",
            style = MaterialTheme.typography.headlineMedium,
            color = colors.primaryText,
        )
        Spacer(Modifier.height(12.dp))
        Text(
            text = "App 壳已装配（组合根 + 主题 + 播放服务）。\n页面将在 feature 层接入后出现。",
            style = MaterialTheme.typography.bodyMedium,
            color = colors.secondaryText,
        )
    }
}
