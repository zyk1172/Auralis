import AppIntents
import Foundation

/// macOS 的快捷指令 / Siri 入口。
/// 与 iOS 共用同一个 `AuralisAskAssistantIntent`（定义在 Apps/Shared），
/// 让 Siri 在 Mac 上也能把请求交给 App 内 AI 助手执行。
struct AuralisMacShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AuralisAskAssistantIntent(),
            phrases: [
                "\(.applicationName) 让 AI 助手操作",
                "\(.applicationName) 问 AI 助手",
            ],
            shortTitle: "问 AI 助手",
            systemImageName: "sparkles"
        )
    }
}
