import AgentKit
import AIKit
import Testing

private let testConfirmation = PendingConfirmation(
    toolName: "test_tool",
    permission: .readOnly,
    title: "确认",
    detail: "确认外发",
    call: ToolCall(name: "test_tool")
)

@Test("任务策略只继承最后一条用户消息")
func taskPolicyUsesOnlyLatestUserMessage() {
    let history = [
        AgentChatMessage(role: .user, messages: [.text("继续构建推荐索引")]),
        AgentChatMessage(role: .assistant, messages: [.error("推荐索引完成事实尚未取得")]),
        AgentChatMessage(role: .assistant, messages: [.toolProgress(step: "正在执行 library_index_v2_status")]),
        AgentChatMessage(role: .assistant, messages: [.confirmation(testConfirmation)]),
        AgentChatMessage(role: .user, messages: [.text("播放一些歌曲")]),
    ]

    #expect(AgentHistoryPolicy.latestUserText(in: history) == "播放一些歌曲")
}

@Test("错误、进度、确认和流式半成品不会进入模型历史")
func modelHistoryDropsRuntimeOnlyMessages() {
    let history = [
        AgentChatMessage(role: .user, messages: [.text("播放一些歌曲")]),
        AgentChatMessage(role: .assistant, messages: [.error("不要继续推荐索引")]),
        AgentChatMessage(role: .assistant, messages: [.toolProgress(step: "library_index_v2_status")]),
        AgentChatMessage(role: .assistant, messages: [.confirmation(testConfirmation)]),
        AgentChatMessage(role: .assistant, messages: [.streaming("半成品")]),
    ]

    let projected = AgentHistoryPolicy.modelMessages(from: history)
    #expect(projected.count == 1)
    #expect(projected.first?.role == .user)
    #expect(projected.first?.content == "播放一些歌曲")
}

@Test("新寒暄不继承旧索引任务，明确短后续才继承相邻用户意图")
func newInputHistoryBoundary() {
    let history = [
        AgentChatMessage(role: .user, messages: [.text("继续构建推荐索引 V2")]),
        AgentChatMessage(role: .assistant, messages: [.text("已处理一批，仍有待分类歌曲")]),
    ]

    #expect(AgentHistoryPolicy.relevantHistoryText(for: "你好", in: history).isEmpty)
    #expect(AgentHistoryPolicy.relevantHistoryText(for: "继续", in: history) == "继续构建推荐索引 V2")
    #expect(AgentHistoryPolicy.modelMessages(from: history, for: "你好").isEmpty)
    #expect(AgentHistoryPolicy.modelMessages(from: history, for: "继续").count == 2)
}
