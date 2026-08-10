import AppIntents
import AppShell
import Foundation

/// 通过 Siri / 快捷指令把一段自然语言请求交给 App 内 AI 助手执行。
///
/// 与 App 内助手共用同一个 `AuralisAppModel.shared.agentCoordinator`，
/// 因此播放、歌单、收藏、推荐等操作都落在与界面完全相同的播放器与服务器上。
/// 无界面模式与 App 内一致，工具调用会直接执行，
/// 并把助手最终回复作为 Siri 语音结果朗读出来。
struct AuralisAskAssistantIntent: AppIntent {
    static let title: LocalizedStringResource = "问 AI 助手"
    static let description = IntentDescription("让 AI 助手播放音乐、管理歌单、推荐歌曲或回答音乐库问题")

    @Parameter(title: "请求内容", requestValueDialog: "你想让 AI 助手做什么？")
    var query: String

    @MainActor
    func perform() async throws -> some IntentResult {
        let reply = await AuralisAppModel.shared.askAssistant(query)
        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        // 统一返回带语音播报的结果：无回复时用默认提示，避免 opaque 类型不一致。
        let dialog = trimmed.isEmpty ? "已处理" : trimmed
        return .result(dialog: "\(dialog)")
    }
}
