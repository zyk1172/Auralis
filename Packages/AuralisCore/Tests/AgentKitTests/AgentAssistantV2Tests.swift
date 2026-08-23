import AIKit
@testable import AgentKit
import Testing

struct AgentAssistantV2Tests {
    @Test("普通聊天不会获得本地音乐降级，明确音乐请求可以降级")
    func offlineFallbackRequiresExplicitMusicCommand() {
        #expect(!ConversationEngine.allowsOfflineFallback(intent: .conversation, userText: "解释一下黑洞是什么"))
        #expect(!ConversationEngine.allowsOfflineFallback(intent: .conversation, userText: "你是谁"))
        #expect(ConversationEngine.allowsOfflineFallback(intent: .librarySearch, userText: "帮我找歌 夜曲"))
        #expect(ConversationEngine.allowsOfflineFallback(intent: .playbackControl, userText: "暂停播放"))
    }

    @Test("ToolCatalog 是发现工具的唯一搜索源")
    func catalogSearchesRegisteredDescriptors() throws {
        let catalog = ToolCatalog()
        let web = catalog.search(query: "联网")
        #expect(web.contains { $0.name == "web_search" })
        #expect(catalog.descriptor(named: "tools_list")?.name == "tool_search")
        #expect(catalog.descriptor(named: "music_download_search")?.name == "music_download_search")
    }

    @Test("ToolRuntime 在副作用前校验必填和结构化参数")
    func validatesArgumentsBeforeExecution() throws {
        let descriptor = try #require(AgentToolRegistry.descriptor(for: "queue_replace"))
        #expect(throws: ToolRuntimeError.missingParameter("trackIDs")) {
            try ToolRuntime.validate(ToolCall(name: descriptor.name), descriptor: descriptor)
        }
        #expect(throws: ToolRuntimeError.invalidParameter(name: "trackIDs", expected: "JSON array", value: "not-json")) {
            try ToolRuntime.validate(
                ToolCall(name: descriptor.name, arguments: ["trackIDs": "not-json"]),
                descriptor: descriptor
            )
        }
    }

    @Test("严格工具 schema 禁止未声明参数")
    func emitsClosedObjectSchema() throws {
        let descriptor = try #require(AgentToolRegistry.descriptor(for: "tool_search"))
        let schema = try #require(ToolSelector.parametersJSON(for: descriptor))
        #expect(schema.contains("additionalProperties"))
        #expect(schema.contains("false"))
    }

    @Test("Provider capability mode differentiates native and textual protocols")
    func providerCapabilityMode() {
        let native = ModelCapabilities(supportsToolCalling: true, toolMode: .anthropicMessages)
        let textual = ModelCapabilities(supportsToolCalling: false, toolMode: .textualToolProtocol)
        #expect(native.toolMode == .anthropicMessages)
        #expect(native.supportsToolChoice)
        #expect(textual.toolMode == .textualToolProtocol)
    }

    @Test("WorkflowEngine 只编排批处理，不把意图当成工具权限")
    func routesBatchWorkflows() {
        let index = WorkflowEngine.route(intent: .libraryManagement, text: "重建推荐索引 V2，全部处理")
        #expect(index.kind == .recommendationIndexV2)
        #expect(index.usesRecommendationIndexV2)
        #expect(index.usesBatchTools)

        let download = WorkflowEngine.route(intent: .musicDownload, text: "下载这张专辑")
        #expect(download.kind == .batchDownload)
        #expect(download.usesBatchTools)

        let chat = WorkflowEngine.route(intent: .conversation, text: "解释一下黑洞是什么")
        #expect(chat.kind == .generic)
        #expect(!chat.usesBatchTools)
    }

    @Test("tool_search 的结果可以被加入下一轮 schema")
    func discoveredToolCanBeSchemaEncoded() throws {
        let entries = ToolCatalog().search(query: "web")
        let descriptors = try entries.map { entry in
            try #require(AgentToolRegistry.descriptor(for: entry.name))
        }
        let definitions = ToolSelector.toolDefinitions(from: descriptors, strict: true)
        #expect(definitions.contains { $0.name == "web_search" })
        #expect(definitions.contains { $0.name == "web_fetch" })
        #expect(!definitions.contains { !$0.strict })
    }
}
