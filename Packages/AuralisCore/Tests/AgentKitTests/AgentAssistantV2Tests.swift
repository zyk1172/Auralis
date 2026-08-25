import AIKit
@testable import AgentKit
import Testing

struct AgentAssistantV2Tests {

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
        let native = ModelCapabilities(
            supportsToolCalling: true,
            supportsToolChoice: true,
            toolMode: .anthropicMessages
        )
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
        #expect(WorkflowEngine.route(intent: start.intent, text: "开始索引 V2").kind == .recommendationIndex)

        let index = WorkflowEngine.route(intent: .libraryManagement, text: "重建推荐索引 V2，全部处理")
        #expect(index.kind == .recommendationIndex)
        #expect(index.usesRecommendationIndex)
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

    @Test("Recommendation Index private tools require the trusted skill")
    func recommendationIndexPrivateToolsRequireSkill() {
        let ordinary = ToolSelector.select(for: "开始构建推荐索引", all: AgentToolRegistry.all)
        let ordinaryNames = Set(ordinary.map(\.name))
        #expect(!ordinaryNames.contains("library_index_v2_next_batch"))
        #expect(!ordinaryNames.contains("library_index_v2_write_batch"))
        #expect(!ToolCatalog().search(query: "library_index_v2_next_batch").contains { $0.name == "library_index_v2_next_batch" })
        #expect(!ToolCatalog().search(query: "library_index_v2_write_batch").contains { $0.name == "library_index_v2_write_batch" })

        let active = ToolSelector.select(
            for: "开始构建推荐索引",
            intent: .libraryManagement,
            policy: AgentTaskPolicy.policy(for: .libraryManagement),
            all: AgentToolRegistry.all,
            activeSkillID: "recommendation-index"
        )
        let activeNames = Set(active.map(\.name))
        #expect(activeNames.contains("library_index_status"))
        #expect(!activeNames.contains("library_index_v2_next_batch"))
        #expect(!activeNames.contains("library_index_v2_write_batch"))
    }

    @Test("Every model-visible write declares a canonical authorization operation")
    func modelVisibleWritesDeclareLeastPrivilegeOperation() {
        let missing = AgentToolRegistry.all
            .filter { $0.visibility == .model && $0.permission != .readOnly && $0.authorizationOperation == nil }
            .map(\.name)
        #expect(missing.isEmpty, "缺少逐操作授权声明：\(missing.sorted().joined(separator: ", "))")
    }

    @Test("Index status questions never activate the build workflow")
    func indexQueriesDoNotStartBuild() {
        let queries = [
            "索引处理了几首歌",
            "推荐索引分类了多少首",
            "现在索引进度怎么样",
            "索引还剩多少首",
            "推荐索引全部处理完了吗",
        ]
        for query in queries {
            let semantics = AgentRequestSemantics.analyze(query)
            #expect(semantics.isRecommendationIndex)
            #expect(!semantics.isRecommendationIndexBuild, "查询不应启动构建：\(query)")
            #expect(AgentTaskPolicyResolver.resolve(text: query).completion != .indexPendingCountIsZero)
            #expect(WorkflowEngine.route(intent: .libraryManagement, text: query).kind == .generic)
        }
    }

    @Test("Recommendation Index natural language uses one executable build route")
    func recommendationIndexNaturalLanguageBuildRoute() {
        let executableRequests = [
            "建立推荐索引",
            "帮我建立推荐索引",
            "创建推荐索引",
            "生成推荐索引",
            "开始建立推荐索引",
            "重建推荐索引",
            "继续构建推荐索引",
            "把推荐索引做完",
        ]

        for text in executableRequests {
            let semantics = AgentRequestSemantics.analyze(text)
            let policy = AgentTaskPolicyResolver.resolve(text: text)
            let route = WorkflowEngine.route(
                intent: .libraryManagement,
                text: text,
                semantics: semantics
            )

            #expect(semantics.isRecommendationIndex, "必须识别推荐索引 target：\(text)")
            #expect(semantics.isRecommendationIndexBuild, "必须识别 build action：\(text)")
            #expect(semantics.operation == .mutate, "执行请求必须是 mutate：\(text)")
            #expect(semantics.requestedOperations.contains(.recommendationIndexWrite))
            #expect(semantics.requiresSideEffect)
            #expect(policy.intent == .libraryManagement)
            #expect(policy.completion == .indexPendingCountIsZero)
            #expect(route.kind == .recommendationIndex)
            #expect(route.usesRecommendationIndex)
        }
    }

    @Test("Recommendation Index status and instructional questions stay read-only")
    func recommendationIndexReadAndInstructionalRoute() {
        let readOnlyQueries = [
            "推荐索引是什么？",
            "查看推荐索引状态",
            "推荐索引进度怎么样",
        ]
        let instructionalQueries = [
            "怎么建立推荐索引？",
            "如何重建推荐索引？",
        ]

        for text in readOnlyQueries + instructionalQueries {
            let semantics = AgentRequestSemantics.analyze(text)
            let policy = AgentTaskPolicyResolver.resolve(text: text)
            let route = WorkflowEngine.route(
                intent: .libraryManagement,
                text: text,
                semantics: semantics
            )

            #expect(semantics.isRecommendationIndex, "必须识别推荐索引 target：\(text)")
            #expect(!semantics.isRecommendationIndexBuild, "只读/教学请求不得启动 build：\(text)")
            #expect(!semantics.requestedOperations.contains(.recommendationIndexWrite))
            #expect(!semantics.requiresSideEffect)
            #expect(semantics.operation != .mutate)
            #expect(policy.completion != .indexPendingCountIsZero)
            #expect(route.kind == .generic)
            #expect(!route.usesRecommendationIndex)
        }
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
