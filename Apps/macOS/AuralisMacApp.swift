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
            MacMusicShell(model: .shared, themeStore: themeStore)
                .frame(minWidth: 900, minHeight: 600)
        }
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("播放") {
                // Space 播放/暂停的唯一入口在 MacMusicShell 的 .onKeyPress(.space)，
                // 这里不注册裸 Space 菜单快捷键，避免 AppKit 菜单 key-equivalent 在文本输入框抢键。
                Button("播放 / 暂停") { post(MacCommand.togglePlay) }
                Button("上一首") { post(MacCommand.previous) }
                    .keyboardShortcut(.leftArrow, modifiers: .command)
                Button("下一首") { post(MacCommand.next) }
                    .keyboardShortcut(.rightArrow, modifiers: .command)
                Divider()
                Button("随机播放") { post(MacCommand.toggleShuffle) }
                Button("循环模式") { post(MacCommand.cycleRepeat) }
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
            }
            CommandGroup(after: .sidebar) {
                Divider()
                Button("搜索") { post(MacCommand.search) }
                    .keyboardShortcut("f", modifiers: .command)
                Button("正在播放") { post(MacCommand.revealNowPlaying) }
                    .keyboardShortcut("l", modifiers: .command)
                Button("显示或隐藏歌词") { post(MacCommand.toggleLyrics) }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                Button("显示或隐藏队列") { post(MacCommand.toggleQueue) }
                    .keyboardShortcut("q", modifiers: [.command, .shift])
                Button("显示或隐藏检查器") { post(MacCommand.toggleInspector) }
                    .keyboardShortcut("i", modifiers: [.command, .option])
                Button("显示或隐藏侧边栏") { post(MacCommand.toggleSidebar) }
                    .keyboardShortcut("s", modifiers: [.command, .control])
                Divider()
                Button("进入全屏播放") { post(MacCommand.showFullScreenPlayer) }
                    .keyboardShortcut("f", modifiers: [.command, .control])
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
