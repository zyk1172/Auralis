package com.auralis.tv

import androidx.annotation.StringRes
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Home
import androidx.compose.material.icons.filled.LibraryMusic
import androidx.compose.material.icons.filled.Search
import androidx.compose.ui.graphics.vector.ImageVector
import com.auralis.tv.R

/**
 * TV 一级分区（S9）。移动端 Dock = Home / Library / Assistant；TV 无 Assistant，
 * 搜索（Swift `SearchView` 实体）提升为一级分区 —— Android TV 惯例 + 移动端核心能力。
 */
enum class TvSection(@StringRes val labelRes: Int, val icon: ImageVector) {
    Home(R.string.tv_home, Icons.Filled.Home),
    Library(R.string.tv_library, Icons.Filled.LibraryMusic),
    Search(R.string.tv_search, Icons.Filled.Search),
}
