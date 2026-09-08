// SPDX-License-Identifier: GPL-3.0-only
import AgentKit
import AIKit
import Domain
import Foundation
import LocalCatalog
import Testing

@Suite("Tool Runtime infrastructure")
struct ToolRuntimeInfrastructureTests {
    private actor ParallelWebProbe: AgentWebService {
        private var active = 0
        private var peak = 0

        func search(query: String, limit: Int) async throws -> WebSearchResult {
            WebSearchResult(query: query, sources: [])
        }

        func fetch(url: URL) async throws -> WebDocument {
            active += 1
            peak = max(peak, active)
            try? await Task.sleep(nanoseconds: 30_000_000)
            active -= 1
            let source = WebSource(title: url.absoluteString, url: url, snippet: "test")
            return WebDocument(source: source, text: "safe test content")
        }

        func peakConcurrency() -> Int { peak }
    }

    private func schema() -> AIJSONValue {
        .object([
            "type": .string("object"),
            "properties": .object([
                "url": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("url")]),
            "additionalProperties": .bool(false),
        ])
    }

    private func makeStore() throws -> LocalCatalogStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("auralis-runtime-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try LocalCatalogStore(url: directory.appendingPathComponent("catalog.sqlite"))
    }

    @Test("Timeout failures retain a typed, non-retryable envelope")
    func timeoutFailureIsStructured() throws {
        let descriptor = try #require(AgentToolRegistry.descriptor(for: "playlist_delete"))
        let result = ToolRuntime.timeoutResult(
            call: ToolCall(name: descriptor.name),
            descriptor: descriptor
        )

        #expect(!result.success)
        #expect(result.failure?.phase == .timeout)
        #expect(result.failure?.code == "tool_timeout")
        #expect(result.failure?.retryable == false)
        #expect(result.hasIndeterminateSideEffect)
    }

    @Test("Capability coverage is derived from visible descriptors")
    func capabilityCoverageHasNoLegacyTools() {
        let coverage = ToolCatalog().capabilityCoverage()
        #expect(coverage.contains { $0.namespace == "web" })
        #expect(coverage.allSatisfy { !$0.toolNames.contains("music_download") })
        #expect(coverage.allSatisfy { $0.readOnlyCount + $0.mutationCount == $0.toolNames.count })
    }

    @Test("Independent read-only custom HTTP tools execute concurrently")
    func readOnlyToolsRunInParallel() async throws {
        let registry = CustomToolRegistry(storageURL: nil)
        let first = try await registry.create(CustomToolManifest(
            name: "并行读取一",
            description: "read one",
            inputSchema: schema(),
            implementation: .httpRead(CustomHTTPReadToolDefinition(allowedHosts: ["example.com"]))
        ))
        let second = try await registry.create(CustomToolManifest(
            name: "并行读取二",
            description: "read two",
            inputSchema: schema(),
            implementation: .httpRead(CustomHTTPReadToolDefinition(allowedHosts: ["example.com"]))
        ))
        let descriptors = await registry.modelDescriptors()
        let probe = ParallelWebProbe()
        let store = try makeStore()
        let lease = ToolExecutionLease(runID: UUID(), sessionID: UUID(), generation: 1)
        let context = ToolExecutorContext(
            bridge: MockAgentBridge(),
            catalog: store,
            serverID: nil,
            systemService: nil,
            externalMusicService: nil,
            allowsLyrics: false,
            providerCapabilities: nil,
            webService: probe,
            authorizationContext: nil,
            activeSkillID: nil,
            executionAuthority: nil,
            executionLease: lease,
            resourceLeaseRegistry: MutationResourceLeaseRegistry(),
            recommendationIndexExecutionRegistry: RecommendationIndexExecutionRegistry(),
            customToolRegistry: registry,
            availableToolDescriptors: AgentToolRegistry.all + descriptors
        )
        let calls = [
            ToolCall(name: first.canonicalToolName, arguments: ["url": .string("https://example.com/one")]),
            ToolCall(name: second.canonicalToolName, arguments: ["url": .string("https://example.com/two")]),
        ]
        let collector = ToolMetricsCollector(capacity: 8)
        let results = await ToolRuntime.executeReadOnlyParallel(
            calls,
            context: context,
            providerAllowsParallel: true,
            metricsCollector: collector
        )

        #expect(results.count == 2)
        #expect(results.allSatisfy { $0.success })
        #expect(await probe.peakConcurrency() == 2)
        #expect((await collector.snapshot()).count == 2)
    }

    @Test("Semantic analysis keeps read-only artist count out of playback mutation")
    func artistCountIsReadOnly() {
        let semantics = AgentRequestSemantics.analyze("有多少歌手")
        #expect(semantics.operation == .read)
        #expect(!semantics.requestedOperations.contains(.playbackPlay))
        #expect(!semantics.requiresSideEffect)
    }

    @Test("Custom Tool builder language is explicit")
    func customToolVocabularyDoesNotUseGenericToolMentions() {
        let explicit = AgentRequestSemantics.analyze("创建自建工具")
        #expect(explicit.domain == .customTool)
        #expect(explicit.requestedOperations.contains(.customToolCreate))

        let generic = AgentRequestSemantics.analyze("解释一下工具调用是什么")
        #expect(generic.domain == .conversation)
        #expect(generic.requestedOperations.isEmpty)
    }
}
