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
        #expect(AgentIntentClassifier.classify("查一下今天有什么科技新闻") == .conversation)
        #expect(AgentIntentClassifier.classify("查看当前音频输出设备") == .conversation)
        #expect(!ConversationEngine.isExplicitMusicCommand("推荐几本人工智能方面的书"))
        #expect(!ConversationEngine.isExplicitMusicCommand("怎么下载 Python 的 wheel 文件"))
        #expect(!ConversationEngine.isExplicitMusicCommand("为什么 iPhone 充电的时候会发热"))
        #expect(ConversationEngine.isExplicitMusicCommand("推荐几首适合通勤的音乐"))
        #expect(ConversationEngine.isExplicitMusicCommand("暂停播放"))
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
        let start = AgentTaskPolicyResolver.resolve(text: "开始索引 V2")
        #expect(start.intent == .libraryManagement)
        #expect(start.completion == .indexPendingCountIsZero)
        #expect(WorkflowEngine.route(intent: start.intent, text: "开始索引 V2").kind == .recommendationIndexV2)

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

    @Test("legacy tools remain executable but never enter model discovery")
    func legacyToolsAreHiddenFromModel() throws {
        let legacy = try #require(AgentToolRegistry.descriptor(for: "music_download"))
        #expect(legacy.visibility == .legacyOnly)
        #expect(!ToolCatalog().search(query: "music_download").contains { $0.name == "music_download" })

        let definitions = ToolSelector.toolDefinitions(from: AgentToolRegistry.all)
        #expect(!definitions.contains { $0.name == "music_download" })
        #expect(!definitions.contains { $0.name == "playTrack" })
        #expect(definitions.contains { $0.name == "music_download_search" })
    }

    @Test("recursive schema validation checks enum, nested object, arrays and extra keys")
    func recursivelyValidatesStructuredArguments() throws {
        let descriptor = ToolDescriptor(
            name: "structured_test",
            group: .catalog,
            permission: .readOnly,
            summary: "test",
            parameters: [
                .init(name: "mode", required: true, description: "mode", schemaJSON: #"{"type":"string","enum":["off","all"]}"#),
                .init(name: "items", required: true, description: "items", schemaJSON: #"{"type":"array","minItems":1,"maxItems":2,"items":{"type":"object","additionalProperties":false,"properties":{"id":{"type":"string"},"score":{"type":"number","minimum":0,"maximum":1}},"required":["id","score"]}}"#),
            ]
        )
        let valid = ToolCall(name: descriptor.name, arguments: [
            "mode": .string("all"),
            "items": .array([.object(["id": .string("a"), "score": .number(0.5)])]),
        ])
        try ToolRuntime.validate(valid, descriptor: descriptor)

        #expect(throws: ToolRuntimeError.self) {
            try ToolRuntime.validate(
                ToolCall(name: descriptor.name, arguments: [
                    "mode": .string("sometimes"),
                    "items": .array([.object(["id": .string("a"), "score": .number(0.5)])]),
                ]),
                descriptor: descriptor
            )
        }
        #expect(throws: ToolRuntimeError.self) {
            try ToolRuntime.validate(
                ToolCall(name: descriptor.name, arguments: [
                    "mode": .string("all"),
                    "items": .array([.object(["id": .string("a"), "score": .number(0.5), "extra": .bool(true)])]),
                ]),
                descriptor: descriptor
            )
        }
    }
}
