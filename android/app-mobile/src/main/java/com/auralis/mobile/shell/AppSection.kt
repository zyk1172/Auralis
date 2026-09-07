package com.auralis.mobile.shell

import androidx.annotation.StringRes
import com.auralis.mobile.R
import com.auralis.core.designsystem.R as AuralisR

/**
 * 应用一级分区（对齐 Apple `AppSection.compactDockSections`）。
 * 底部 Dock 只有 3 个：Home / Library / Assistant；Search 与 Settings 不作为一级入口。
 */
enum class AppSection(@StringRes val labelRes: Int) {
    Home(AuralisR.string.home_title),
    Library(AuralisR.string.library_title),
    Assistant(AuralisR.string.ai_assistant),
}
