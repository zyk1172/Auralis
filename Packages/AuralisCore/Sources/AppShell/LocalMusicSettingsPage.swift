// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import ThemeEngine

/// Local-library management intentionally lives only in Settings. PR1 exposes the
/// architecture boundary; PR2 supplies platform folder pickers, scanning and playback.
struct LocalMusicSettingsPage: View {
    let theme: BuiltInTheme

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    Text(verbatim: "已启用")
                        .foregroundStyle(theme.colorTokens.secondaryText.color)
                } label: {
                    Label("本地音乐基础架构", systemImage: "music.note.house")
                }
                Text(verbatim: "本地音乐来源、扫描状态、重新扫描和存储位置都将在这里管理，不在资料库主页增加独立设置入口。")
                    .font(.caption)
                    .foregroundStyle(theme.colorTokens.secondaryText.color)
            }
            Section("来源") {
                Text(verbatim: "尚未添加本地音乐来源。文件夹授权与扫描将在下一阶段启用。")
                    .foregroundStyle(theme.colorTokens.secondaryText.color)
            }
        }
        .navigationTitle("本地音乐")
        .scrollContentBackground(.hidden)
        .background(theme.colorTokens.background.color)
    }
}
