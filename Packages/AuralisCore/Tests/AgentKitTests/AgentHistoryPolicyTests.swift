// SPDX-License-Identifier: GPL-3.0-only
import AgentKit
import AIKit
import Domain
import Foundation
import LocalCatalog
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

@Test("完整会话消息会进入模型历史")
func modelHistoryKeepsConversationMessages() {
    let history = [
        AgentChatMessage(role: .user, messages: [.text("播放一些歌曲")]),
        AgentChatMessage(role: .assistant, messages: [.error("不要继续推荐索引")]),
        AgentChatMessage(role: .assistant, messages: [.toolProgress(step: "library_index_v2_status")]),
        AgentChatMessage(role: .assistant, messages: [.confirmation(testConfirmation)]),
        AgentChatMessage(role: .assistant, messages: [.streaming("半成品")]),
        AgentChatMessage(role: .assistant, messages: [.reasoning("内部思考内容")]),
    ]

    let projected = AgentHistoryPolicy.modelMessages(from: history)
    // 运行时进度、错误、确认、流式半成品和 reasoning 只服务当前运行，
    // 不应重新进入模型上下文。
    #expect(projected.count == 1)
    #expect(projected[0].role == .user)
    #expect(projected[0].content == "播放一些歌曲")
}

@Test("任务策略与模型历史彼此独立")
func newInputHistoryBoundary() {
    let history = [
        AgentChatMessage(role: .user, messages: [.text("继续构建推荐索引 V2")]),
        AgentChatMessage(role: .assistant, messages: [.text("已处理一批，仍有待分类歌曲")]),
    ]

    #expect(AgentHistoryPolicy.relevantHistoryText(for: "你好", in: history).isEmpty)
    #expect(AgentHistoryPolicy.relevantHistoryText(for: "继续", in: history) == "继续构建推荐索引 V2")
    #expect(AgentHistoryPolicy.modelMessages(from: history, for: "你好").count == 2)
    #expect(AgentHistoryPolicy.modelMessages(from: history, for: "继续").count == 2)
}

@Test("模型历史默认不受旧的 40 条消息上限限制")
func modelHistoryUsesFullConversationByDefault() {
    let history = (0..<45).map { index in
        AgentChatMessage(
            role: index.isMultiple(of: 2) ? .user : .assistant,
            messages: [.text("消息 \(index)")]
        )
    }

    #expect(AgentHistoryPolicy.modelMessages(from: history).count == 45)
}

@Test("歌曲卡片历史保留 GlobalID 与艺术家专辑信息")
func modelHistoryPreservesTrackIdentity() {
    let card = TrackCard(
        globalID: GlobalID(serverID: "srv", remoteID: "track-42"),
        title: "天亮以前说再见",
        artistName: "林俊杰",
        albumTitle: "新地球",
        duration: 240,
        isFavorite: false
    )
    let projected = AgentHistoryPolicy.modelMessages(from: [
        AgentChatMessage(role: .assistant, messages: [.trackCards([card])])
    ])
    #expect(projected.count == 1)
    #expect(projected[0].content.contains("srv:track-42"))
    #expect(projected[0].content.contains("林俊杰"))
    #expect(projected[0].content.contains("新地球"))
}

@Test("元数据关闭时模型历史不携带歌曲卡片内容")
func modelHistoryHidesTrackCardsWithoutMetadataPermission() {
    let card = TrackCard(
        globalID: GlobalID(serverID: "opaque", remoteID: "private-track"),
        title: "不应外发的歌",
        artistName: "私人艺术家",
        albumTitle: "私人专辑",
        duration: 240,
        isFavorite: true
    )
    var permissions = AIPrivacyPermissions()
    permissions.allowsMetadata = false

    let projected = AgentHistoryPolicy.modelMessages(
        from: [AgentChatMessage(role: .assistant, messages: [.trackCards([card])])],
        for: nil,
        permissions: permissions
    )

    #expect(projected.count == 1)
    #expect(projected[0].content.contains("歌曲结果已按隐私设置隐藏"))
    #expect(!projected[0].content.contains("不应外发的歌"))
    #expect(!projected[0].content.contains("opaque:private-track"))
}

@Test("权限收紧后不回放无结构化来源的 assistant 文本与 action preview")
func modelHistoryHidesOpaqueAssistantTextAfterDisclosureRevocation() {
    var permissions = AIPrivacyPermissions()
    permissions.allowsMetadata = false
    let history = [
        AgentChatMessage(
            role: .assistant,
            messages: [
                .text("播放《私密歌曲》；播放 37 次；已收藏"),
                .actionPreview(title: "播放", detail: "《私密歌曲》"),
            ]
        ),
    ]

    let messages = AgentHistoryPolicy.modelMessages(
        from: history,
        for: nil,
        permissions: permissions
    )
    let text = messages.map(\.content).joined()
    #expect(!text.contains("私密歌曲"))
    #expect(!text.contains("播放 37 次"))
    #expect(text.isEmpty)
}

@Test("连续两次继续仍回溯到最初的完整任务")
func repeatedContinuationKeepsSubstantiveTask() {
    let history = [
        AgentChatMessage(role: .user, messages: [.text("开始并一次性完成推荐索引 V2")]),
        AgentChatMessage(role: .assistant, messages: [.error("HTTP 429：请求过于频繁")]),
        AgentChatMessage(role: .user, messages: [.text("继续")]),
        AgentChatMessage(role: .assistant, messages: [.error("索引工具暂时不可用")]),
        AgentChatMessage(role: .user, messages: [.text("继续")]),
    ]

    #expect(
        AgentHistoryPolicy.relevantHistoryText(for: "继续", in: history)
            == "开始并一次性完成推荐索引 V2"
    )
}

@Test("新完整请求建立新的执行 lineage，不继承旧歌单修改")
func substantiveRequestStartsNewExecutionLineage() {
    let create = ExecutionLineage.newRequest(text: "创建一个空歌单 Test")
    let list = ExecutionLineageResolver.resolve(
        currentUserText: "列出歌单",
        previous: create
    )

    #expect(list.lineageID != create.lineageID)
    #expect(list.taskID == nil)
    #expect(list.authorization.allowedOperations.isEmpty)
    #expect(AgentRequestSemantics.analyze("列出歌单").isReadOnly)
    #expect(AgentIntentClassifier.classify("列出歌单") == .playlistQuery)
    #expect(AgentTaskPolicy.policy(for: .playlistQuery).completion == .modelAnswer)
}

@Test("严格短续写继承原执行 lineage 与最小授权")
func explicitContinuationKeepsExecutionLineage() {
    let original = ExecutionLineage.newRequest(text: "播放《Sunset》")
        .attaching(taskID: UUID())
    let continuation = ExecutionLineageResolver.resolve(
        currentUserText: "第一个",
        previous: original
    )

    #expect(continuation.lineageID == original.lineageID)
    #expect(continuation.taskID == original.taskID)
    #expect(continuation.authorization.allowedOperations == Set([ToolAuthorizationOperation.playbackPlay]))
    #expect(continuation.originUserMessageID != original.originUserMessageID)
}

@Test("实体引用型操作是新请求而非旧任务 continuation")
func entityReferenceMutationStartsNewLineage() {
    let previous = ExecutionLineage.newRequest(text: "找到两个 Sunset 版本")
    let play = ExecutionLineageResolver.resolve(
        currentUserText: "播放它",
        previous: previous
    )

    #expect(play.lineageID != previous.lineageID)
    #expect(play.authorization.allowedOperations == Set([ToolAuthorizationOperation.playbackPlay]))
}
