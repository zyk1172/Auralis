import AIKit
import Domain
import Foundation
import LocalCatalog

/// Legacy source-compatibility surface. New production code enters
/// `ConversationEngine`, which owns `ToolLoop`; this type does not contain the
/// model/tool loop and cannot become a second execution path.
@available(*, deprecated, message: "Use ConversationEngine")
public enum AgentRunner {
    public typealias Context = ToolLoop.Context
    public typealias AgentProgress = ToolLoop.AgentProgress

    public static let toolExecutionTimeout = ToolLoop.toolExecutionTimeout
    public static let roundTimeout = ToolLoop.roundTimeout

    public static func run(
        userText: String,
        provider: (any AIProvider)?,
        model: String,
        bridge: AgentBridge,
        catalog: LocalCatalogStore,
        context: Context,
        history: [AgentChatMessage] = [],
        systemService: (any AgentSystemService)? = nil,
        externalMusicService: (any AgentExternalMusicService)? = nil,
        webService: (any AgentWebService)? = nil,
        intent: AgentTaskIntent? = nil,
        policy: AgentTaskPolicy? = nil,
        initialTaskState: AgentTaskState? = nil,
        toolTimeout: TimeInterval = ToolLoop.toolExecutionTimeout,
        confirm: @escaping @Sendable (PendingConfirmation) async -> Bool,
        emit: @escaping @Sendable (AgentChatMessage) async -> Void,
        log: @escaping @Sendable (AgentActionRecord) async -> Void = { _ in },
        progress: @escaping @Sendable (AgentProgress) async -> Void = { _ in },
        state: @escaping @Sendable (AgentTaskState) async -> Void = { _ in }
    ) async {
        await ConversationEngine().run(
            userText: userText,
            provider: provider,
            model: model,
            bridge: bridge,
            catalog: catalog,
            context: context,
            history: history,
            systemService: systemService,
            externalMusicService: externalMusicService,
            webService: webService,
            intent: intent,
            policy: policy,
            initialTaskState: initialTaskState,
            toolTimeout: toolTimeout,
            confirm: confirm,
            emit: emit,
            log: log,
            progress: progress,
            state: state
        )
    }

    public static func systemPrompt(
        context: Context,
        tools: [ToolDescriptor],
        nativeToolCalling: Bool,
        goal: String = ""
    ) -> String {
        ToolLoop.systemPrompt(
            context: context,
            tools: tools,
            nativeToolCalling: nativeToolCalling,
            goal: goal
        )
    }
}
