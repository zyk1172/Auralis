package com.auralis.mobile.shell

/**
 * 应用一级分区（对齐 Apple `AppSection.compactDockSections`）。
 * 底部 Dock 只有 3 个：Home / Library / Assistant；Search 与 Settings 不作为一级入口。
 */
enum class AppSection(val title: String) {
    Home("首页"),
    Library("音乐库"),
    Assistant("AI 助手"),
}
