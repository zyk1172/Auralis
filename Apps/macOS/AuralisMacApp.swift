import AppShell
import SwiftUI
import ThemeEngine

@main
struct AuralisMacApp: App {
    /// 唯一长期 ThemeStore：主窗口与 Settings Scene 共享。
    @StateObject private var themeStore = ThemeStore()

    var body: some Scene {
        WindowGroup("澜音") {
            MacMusicShell(model: .shared, themeStore: themeStore)
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
                Button("上一首") { post(MacCommand.previous) }
                    .keyboardShortcut(.leftArrow, modifiers: .command)
                Button("下一首") { post(MacCommand.next) }
                    .keyboardShortcut(.rightArrow, modifiers: .command)
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
            CommandMenu("窗口") {
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
        Window("全屏播放", id: MacWindowID.fullScreenPlayer) {
            MacFullScreenPlayerWindow(themeStore: themeStore)
        }
        Settings {
            MacSettingsHost(themeStore: themeStore)
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
