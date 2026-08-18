import AppShell
import SwiftUI
import ThemeEngine

@main
struct AuralisMacApp: App {
    /// Dock 图标点击恢复主窗口（迷你播放器模式时主窗口被隐藏）。
    @NSApplicationDelegateAdaptor(AuralisMacAppDelegate.self)
    private var appDelegate

    /// 唯一长期 ThemeStore：主窗口与 Settings Scene 共享。
    @StateObject private var themeStore = ThemeStore()
    /// 设置路由：主窗口错误恢复可深链到 Settings 的「服务器」分类。
    @StateObject private var settingsRouter = MacSettingsRouter()

    var body: some Scene {
        WindowGroup("Auralis") {
            MacMusicShell(model: .shared, themeStore: themeStore, settingsRouter: settingsRouter)
                .frame(minWidth: 900, minHeight: 600)
        }
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandGroup(after: .newItem) {
                Button("新建播放列表") { post(MacCommand.newPlaylist) }
                    .keyboardShortcut("n", modifiers: .command)
            }
            CommandMenu("播放") {
                // Space 播放/暂停唯一入口在 MacMusicShell 的 .onKeyPress(.space)。
                Button("播放 / 暂停") { post(MacCommand.togglePlay) }
                // 对齐 Apple Music：上一首/下一首使用 plain ← / →（由 Shell onKeyPress 处理），
                // 菜单里不再注册 Command-←/→，避免与系统/Apple Music 语义冲突。
                Button("上一首") { post(MacCommand.previous) }
                Button("下一首") { post(MacCommand.next) }
                Divider()
                Button("随机播放") { post(MacCommand.toggleShuffle) }
                Button("循环模式") { post(MacCommand.cycleRepeat) }
                Divider()
                Button("音量提高") { adjustVolume(+0.05) }
                    .keyboardShortcut(.upArrow, modifiers: .command)
                Button("音量降低") { adjustVolume(-0.05) }
                    .keyboardShortcut(.downArrow, modifiers: .command)
            }
            CommandMenu("歌曲") {
                Button("收藏当前歌曲") {
                    let model = AuralisAppModel.shared
                    guard model.hasCurrentTrack else { return }
                    model.toggleFavorite(model.currentTrack)
                }
                Button("不喜欢当前歌曲") {
                    let model = AuralisAppModel.shared
                    guard model.hasCurrentTrack else { return }
                    let track = model.currentTrack
                    model.setDisliked(track, value: !model.isDisliked(track), source: "menu")
                }
                Button("当前歌曲信息") {
                    let model = AuralisAppModel.shared
                    guard model.hasCurrentTrack else { return }
                    NotificationCenter.default.post(name: MacCommand.showTrackInformation, object: model.currentTrack)
                }
                .keyboardShortcut("i", modifiers: .command)
            }
            CommandMenu("显示") {
                Button("显示或隐藏侧边栏") { post(MacCommand.toggleSidebar) }
                    .keyboardShortcut("s", modifiers: [.command, .control])
                Button("歌词") { post(MacCommand.toggleLyrics) }
                    .keyboardShortcut("l", modifiers: [.command, .option])
                Button("队列") { post(MacCommand.toggleQueue) }
                    .keyboardShortcut("u", modifiers: [.command, .option])
                Button("正在播放") { post(MacCommand.revealNowPlaying) }
                    .keyboardShortcut("l", modifiers: .command)
                Button("搜索") { post(MacCommand.search) }
                    .keyboardShortcut("f", modifiers: .command)
            }
            CommandMenu("播放器") {
                Button("迷你播放器") { post(MacCommand.showMiniPlayer) }
                    .keyboardShortcut("m", modifiers: [.command, .option])
                Button("全屏播放") { post(MacCommand.showFullScreenPlayer) }
                    .keyboardShortcut("f", modifiers: [.command, .shift])
            }
        }
        Window("迷你播放器", id: MacWindowID.miniPlayer) {
            MacMiniPlayerWindow(themeStore: themeStore)
        }
        .windowResizability(.contentSize)
        // 像 Apple Music 一样默认出现在屏幕右下，而不是屏幕正中央。
        .defaultPosition(.bottomTrailing)
        Settings {
            MacSettingsHost(themeStore: themeStore, settingsRouter: settingsRouter)
        }
    }

    private func post(_ name: Notification.Name) {
        NotificationCenter.default.post(name: name, object: nil)
    }

    private func adjustVolume(_ delta: Float) {
        let model = AuralisAppModel.shared
        model.setVolume(min(1, max(0, model.volume + delta)))
    }
}

/// 设置窗口宿主：使用与主窗口共享的 AppModel / ThemeStore（组合根注入）。
struct MacSettingsHost: View {
    @ObservedObject var model: AuralisAppModel
    @ObservedObject var themeStore: ThemeStore
    @ObservedObject var settingsRouter: MacSettingsRouter

    init(themeStore: ThemeStore, model: AuralisAppModel = .shared, settingsRouter: MacSettingsRouter) {
        self.themeStore = themeStore
        self.model = model
        self.settingsRouter = settingsRouter
    }

    var body: some View {
        MacSettingsWindow(model: model, themeStore: themeStore, settingsRouter: settingsRouter)
            .environmentObject(model)
            .environmentObject(themeStore)
    }
}


/// App 生命周期委托：点击 Dock 图标时恢复主窗口。
/// MiniPlayer 模式会把主窗口 orderOut 隐藏，若没有这个回调，
/// 用户点击 Dock 图标将无法找回主窗口。
final class AuralisMacAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        Task { @MainActor in
            MacWindowVisibilityCoordinator.shared.restoreMainPlayer(expandPlayer: false)
        }
        return true
    }
}
