// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.tv

import androidx.annotation.StringRes
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.Home
import androidx.compose.material.icons.filled.LibraryMusic
import androidx.compose.material.icons.filled.Search
import androidx.compose.ui.graphics.vector.ImageVector
import com.auralis.core.designsystem.R as AuralisR

/**
 * TV 一级分区。播放页不再作为内容列表底部的“播放条”入口，而由导航 rail 底部的
 * Now Playing 动态入口单独承载；设置继续保留在音乐库页右上角，避免重复入口。
 */
enum class TvSection(@StringRes val labelRes: Int, val icon: ImageVector) {
    Home(AuralisR.string.home_title, Icons.Filled.Home),
    Library(AuralisR.string.library_title, Icons.Filled.LibraryMusic),
    Search(R.string.tv_search, Icons.Filled.Search),
    Assistant(R.string.tv_assistant, Icons.Filled.AutoAwesome),
}
