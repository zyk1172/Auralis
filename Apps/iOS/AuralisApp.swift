import AppShell
import SwiftUI
import UIKit

@main
struct AuralisApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            AuralisRootView()
                .onChange(of: scenePhase) { _, phase in
                    // 回到前台时静默做一次增量同步；进入后台/回前台时确保音频会话保持激活。
                    switch phase {
                    case .active:
                        Task {
                            await AuralisAppModel.shared.keepAudioSessionActive()
                            await AuralisAppModel.shared.refreshCatalogInBackground()
                        }
                    case .background:
                        Task { await AuralisAppModel.shared.keepAudioSessionActive() }
                    default:
                        break
                    }
                }
        }
    }
}

/// 转发后台下载会话完成事件：系统在 App 挂起后恢复下载并在结束时调用这里。
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        AuralisAppModel.shared.handleBackgroundDownloadEvents(identifier: identifier, completion: completionHandler)
    }
}
