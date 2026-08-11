import AppShell
import SwiftUI
import ThemeEngine

@main
struct AuralisMacApp: App {
    /// 唯一长期 ThemeStore：主窗口与 Settings Scene 共享，
    /// 避免设置里换主题后主窗口不刷新（ThemeStore 不跨实例监听）。
    @StateObject private var themeStore = ThemeStore()

    var body: some Scene {
        WindowGroup("澜音") {
            AuralisRootView(model: .shared, themeStore: themeStore)
                .frame(minWidth: 760, minHeight: 520)
        }
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("播放") {
                Button("上一首") { post(MacCommandNotification.previous) }
                    .keyboardShortcut(.leftArrow, modifiers: .command)
                Button("下一首") { post(MacCommandNotification.next) }
                    .keyboardShortcut(.rightArrow, modifiers: .command)
                // Space 播放/暂停的唯一入口在 MacAuralisRootView 的 .onKeyPress(.space)，
                // 这里不注册裸 Space 菜单快捷键，避免 AppKit 菜单 key-equivalent 在文本输入框抢键。
                Button("播放 / 暂停") { post(MacCommandNotification.togglePlay) }
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
            MacSettingsHost(themeStore: themeStore)
        }
    }

    private func post(_ name: Notification.Name) {
        NotificationCenter.default.post(name: name, object: nil)
    }
}



/// 设置窗口宿主：使用与主窗口共享的 AppModel / ThemeStore（组合根注入）。
struct MacSettingsHost: View {
    @ObservedObject var model: AuralisAppModel
    @ObservedObject var themeStore: ThemeStore

    init(themeStore: ThemeStore, model: AuralisAppModel = .shared) {
        self.themeStore = themeStore
        self.model = model
    }

    var body: some View {
        MacSettingsWindow(model: model, themeStore: themeStore)
            .environmentObject(model)
            .environmentObject(themeStore)
    }
}
