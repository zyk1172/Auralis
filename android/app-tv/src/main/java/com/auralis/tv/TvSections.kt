package com.auralis.tv

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Home
import androidx.compose.material.icons.filled.LibraryMusic
import androidx.compose.material.icons.filled.Search
import androidx.compose.ui.graphics.vector.ImageVector

/**
 * TV 一级分区（S9）。移动端 Dock = Home / Library / Assistant；TV 无 Assistant，
 * 搜索（Swift `SearchView` 实体）提升为一级分区 —— Android TV 惯例 + 移动端核心能力。
 */
enum class TvSection(val title: String, val icon: ImageVector) {
    Home("首页", Icons.Filled.Home),
    Library("音乐库", Icons.Filled.LibraryMusic),
    Search("搜索", Icons.Filled.Search),
}
