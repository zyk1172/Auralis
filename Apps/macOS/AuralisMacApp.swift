import AppShell
import SwiftUI
import ThemeEngine

@main
struct AuralisMacApp: App {
    var body: some Scene {
        WindowGroup("澜音") {
            AuralisRootView()
                .frame(minWidth: 760, minHeight: 520)
        }
        // 隐藏 macOS 窗口标题栏：内容延伸到窗口顶部，消除系统白色标题条，
        // 黑色主题下不再出现一条与背景割裂的空条。
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("播放") {
                Button("上一首") { post(MacCommandNotification.previous) }
                    .keyboardShortcut(.leftArrow, modifiers: .command)
                Button("下一首") { post(MacCommandNotification.next) }
                    .keyboardShortcut(.rightArrow, modifiers: .command)
                Button("播放 / 暂停") { post(MacCommandNotification.togglePlay) }
                    .keyboardShortcut(.space, modifiers: [])
            }
            CommandGroup(after: .sidebar) {
                Divider()
                Button("搜索") { post(MacCommandNotification.search) }
                    .keyboardShortcut("f", modifiers: .command)
                Button("定位当前歌曲") { post(MacCommandNotification.revealNowPlaying) }
                    .keyboardShortcut("l", modifiers: .command)
                Button("显示或隐藏检查器") { post(MacCommandNotification.toggleInspector) }
                    .keyboardShortcut("i", modifiers: [.command, .option])
            }
        }
        Settings {
            MacSettingsHost()
        }
    }

    private func post(_ name: Notification.Name) {
        NotificationCenter.default.post(name: name, object: nil)
    }
}

/// 设置窗口宿主：持有与主窗口共享的 AppModel / ThemeStore。
struct MacSettingsHost: View {
    @StateObject private var model = AuralisAppModel.shared
    @StateObject private var themeStore = ThemeStore()

    var body: some View {
        MacSettingsWindow(model: model, themeStore: themeStore)
            .environmentObject(model)
            .environmentObject(themeStore)
    }
}
