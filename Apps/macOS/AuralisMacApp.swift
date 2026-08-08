import AppShell
import SwiftUI
import ThemeEngine

@main
struct AuralisMacApp: App {
    init() {
        #if DEBUG
        runStartupProbeIfRequested()
        #endif
    }

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

#if DEBUG
/// 仅 DEBUG 诊断：`open -a Auralis --args -AuralisProbe=host:port`
/// 会在启动时用 NWConnection 对指定局域网端点做一次真实 TCP 连接，
/// 把结果写入 /tmp/auralis_probe_result.txt 后立即退出。
/// 用途：从 /Applications 用 LaunchServices 启动时，验证 TCC「本地网络」
/// 权限是否拦截（unsatisfiedReason == localNetworkDenied），
/// 不依赖 UI 点击，也不触碰 OpenSubsonic 请求链路。
private func runStartupProbeIfRequested() {
    let args = ProcessInfo.processInfo.arguments
    guard let idx = args.firstIndex(where: { $0.hasPrefix("-AuralisProbe=") }) else { return }
    let spec = String(args[idx].dropFirst("-AuralisProbe=".count))
    // 支持 host:port 或 host:port:seconds（探测窗口秒数，默认 10）
    let parts = spec.split(separator: ":")
    let timeout: TimeInterval
    if parts.count == 3, let t = Double(parts[2]) {
        timeout = t
    } else {
        timeout = 10
    }
    guard parts.count >= 2, let port = UInt16(parts[1]) else {
        let msg = "invalid spec: \(spec)"
        NSLog("[AuralisProbe] %@", msg)
        writeProbeResult(msg)
        exit(2)
    }
    Task {
        let result = await LocalNetworkProbe.probe(host: String(parts[0]), port: port, timeout: timeout)
        let line = "host=\(parts[0]) port=\(port) state=\(result.state.rawValue) reason=\(result.unsatisfiedReason ?? "nil") error=\(result.errorDescription ?? "nil") denied=\(result.isLocalNetworkDenied)"
        NSLog("[AuralisProbe] %@", line)
        writeProbeResult(line)
        exit(0)
    }
}
#endif

/// 探测结果写入沙箱容器 tmp（沙箱内不可写 /tmp），并在文件里附上时间戳。
private func writeProbeResult(_ text: String) {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("auralis_probe_result.txt")
    let stamped = "\(Date()) \(text)\n"
    try? stamped.write(to: url, atomically: true, encoding: .utf8)
    NSLog("[AuralisProbe] wrote result to %@", url.path)
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
