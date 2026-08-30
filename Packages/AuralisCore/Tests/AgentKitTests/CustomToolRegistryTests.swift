import AgentKit
import AIKit
import Foundation
import Testing

@Suite("Declarative Custom Tools")
struct CustomToolRegistryTests {
    private func makeRegistry() -> CustomToolRegistry {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("auralis-custom-tools-\(UUID().uuidString).json")
        return CustomToolRegistry(storageURL: url)
    }

    private func objectSchema(_ properties: [String: AIJSONValue] = [:]) -> AIJSONValue {
        .object([
            "type": .string("object"),
            "properties": .object(properties),
            "additionalProperties": .bool(false),
        ])
    }

    @Test("Custom Tool metadata is derived from the implementation")
    func derivesReadOnlyNetworkMetadata() async throws {
        let registry = makeRegistry()
        let manifest = CustomToolManifest(
            name: "读取天气",
            description: "读取公开天气页面",
            inputSchema: objectSchema([
                "url": .object(["type": .string("string")]),
            ]),
            implementation: .httpRead(CustomHTTPReadToolDefinition(
                urlArgument: "url",
                allowedHosts: ["example.com"]
            ))
        )

        #expect(await registry.validate(manifest).isEmpty)
        let saved = try await registry.create(manifest)
        let descriptor = try #require(await registry.descriptor(named: saved.canonicalToolName))
        #expect(descriptor.permission == .readOnly)
        #expect(descriptor.risk == .none)
        #expect(descriptor.networkAccess)
        #expect(descriptor.customToolID == saved.id)
        #expect(descriptor.customToolVersion == 1)
        #expect(descriptor.derivedMutationScopes.isEmpty)
    }

    @Test("Custom Tool cannot lower the risk of an irreversible child")
    func propagatesIrreversibleRiskAndScope() async throws {
        let registry = makeRegistry()
        let manifest = CustomToolManifest(
            name: "删除测试歌单",
            description: "删除一个歌单",
            inputSchema: objectSchema([
                "playlistID": .object(["type": .string("string")]),
            ]),
            implementation: .workflow(steps: [
                CustomToolStep(tool: "playlist_delete", arguments: [
                    "playlistID": .string("$input.playlistID"),
                ])
            ])
        )

        #expect(await registry.validate(manifest).isEmpty)
        let saved = try await registry.create(manifest)
        let descriptor = try #require(await registry.descriptor(named: saved.canonicalToolName))
        #expect(descriptor.permission == .destructive)
        #expect(descriptor.confirmationPolicy.requiresExplicitUserApproval)
        #expect(descriptor.risk == .irreversibleDelete)
        #expect(descriptor.mutationScopes == [.playlist])
        #expect(descriptor.mutationResources == [.playlist])
        #expect(descriptor.derivedAuthorizationOperations == [.playlistDelete])
    }

    @Test("Custom Tool keeps operation metadata without blocking local execution")
    func customToolRetainsOperationMetadataWithoutExecutionWhitelist() async throws {
        let registry = makeRegistry()
        let manifest = CustomToolManifest(
            name: "添加并改名歌单",
            description: "组合两个歌单操作",
            implementation: .workflow(steps: [
                CustomToolStep(tool: "playlist_add_songs"),
                CustomToolStep(tool: "playlist_rename"),
            ])
        )
        let saved = try await registry.create(manifest)
        let descriptor = try #require(await registry.descriptor(named: saved.canonicalToolName))
        #expect(descriptor.derivedAuthorizationOperations == [.playlistAdd, .playlistRename])

        let addOnly = SideEffectAuthorizationContext(originalUserRequest: "把歌曲加入歌单")
        #expect(addOnly.allows(descriptor))
        #expect(addOnly.allowedOperations == [.playlistAdd])

        let both = SideEffectAuthorizationContext(originalUserRequest: "把歌曲加入歌单并重命名歌单")
        #expect(both.allows(descriptor))
    }

    @Test("Custom Tool persistence failure does not change in-memory state")
    func persistenceFailureIsAtomic() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("auralis-custom-tool-directory-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let registry = CustomToolRegistry(storageURL: directory)
        let manifest = CustomToolManifest(
            name: "不会保存",
            description: "写入目录路径应失败",
            implementation: .httpRead(CustomHTTPReadToolDefinition(allowedHosts: ["example.com"]))
        )

        do {
            _ = try await registry.create(manifest)
            Issue.record("向目录路径写入时不应返回成功")
        } catch let error as CustomToolRegistryError {
            #expect(error == .persistenceFailed)
        }
        #expect(await registry.list().isEmpty)
    }

    @Test("Custom Tool updates retain history and rollback creates a new version")
    func versionsCanRollback() async throws {
        let registry = makeRegistry()
        let original = CustomToolManifest(
            name: "版本工具",
            description: "第一版",
            implementation: .httpRead(CustomHTTPReadToolDefinition(allowedHosts: ["example.com"]))
        )
        let first = try await registry.create(original)
        var changed = first
        changed.description = "第二版"
        let second = try await registry.update(changed)
        #expect(second.version == 2)

        let rolledBack = try await registry.rollback(id: first.id, toVersion: 1)
        #expect(rolledBack.version == 3)
        #expect(rolledBack.description == "第一版")
        #expect((await registry.history(id: first.id)).map(\.version) == [1, 2, 3])
    }

    @Test("Custom Tool snapshots advance atomically and remove disabled/deleted tools")
    func snapshotsTrackRegistryMutations() async throws {
        let registry = makeRegistry()
        let initial = await registry.modelSnapshot()
        #expect(initial.revision == 0)
        #expect(initial.descriptors.isEmpty)

        let saved = try await registry.create(CustomToolManifest(
            name: "快照工具",
            description: "验证运行中刷新",
            implementation: .httpRead(CustomHTTPReadToolDefinition(allowedHosts: ["example.com"]))
        ))
        let created = await registry.modelSnapshot()
        #expect(created.revision == initial.revision + 1)
        #expect(created.descriptors.contains { $0.customToolID == saved.id && $0.customToolVersion == 1 })

        var changed = saved
        changed.description = "更新后的工具"
        _ = try await registry.update(changed)
        let updated = await registry.modelSnapshot()
        #expect(updated.revision == created.revision + 1)
        #expect(updated.descriptors.first(where: { $0.customToolID == saved.id })?.customToolVersion == 2)

        _ = try await registry.setEnabled(id: saved.id, enabled: false)
        let disabled = await registry.modelSnapshot()
        #expect(disabled.revision == updated.revision + 1)
        #expect(!disabled.descriptors.contains { $0.customToolID == saved.id })

        try await registry.delete(id: saved.id)
        let deleted = await registry.modelSnapshot()
        #expect(deleted.revision == disabled.revision + 1)
        #expect(!deleted.descriptors.contains { $0.customToolID == saved.id })
    }

    @Test("Custom Tool validation rejects a legacy or nested child")
    func rejectsUnsafeComposition() async throws {
        let registry = makeRegistry()
        let legacy = CustomToolManifest(
            name: "旧工具组合",
            description: "不应暴露 legacy",
            implementation: .workflow(steps: [CustomToolStep(tool: "music_download")])
        )
        #expect(await registry.validate(legacy).contains(.legacyChildTool("music_download")))

        let nestedBase = CustomToolManifest(
            name: "基础自建工具",
            description: "用于嵌套校验",
            implementation: .httpRead(CustomHTTPReadToolDefinition(allowedHosts: ["example.com"]))
        )
        let saved = try await registry.create(nestedBase)
        let nested = CustomToolManifest(
            name: "嵌套自建工具",
            description: "不允许递归组合",
            implementation: .workflow(steps: [CustomToolStep(tool: saved.canonicalToolName)])
        )
        #expect(await registry.validate(nested).contains(.nestedCustomTool(saved.canonicalToolName)))
    }

    @Test("HTTP custom tools require an explicit safe host allowlist")
    func rejectsOpenHTTPRead() async {
        let registry = makeRegistry()
        let open = CustomToolManifest(
            name: "开放网页读取",
            description: "不应允许任意主机",
            implementation: .httpRead(CustomHTTPReadToolDefinition())
        )
        #expect(await registry.validate(open).contains(.missingHTTPHostAllowlist))

        let privateHost = CustomToolManifest(
            name: "私网网页读取",
            description: "不应允许私网主机",
            implementation: .httpRead(CustomHTTPReadToolDefinition(allowedHosts: ["127.0.0.1"]))
        )
        #expect(await registry.validate(privateHost).contains(.unsafeHTTPHost("127.0.0.1")))
    }

    @Test("Repair proposals cannot replace another custom tool ID")
    func repairRejectsMismatchedID() async throws {
        let registry = makeRegistry()
        let saved = try await registry.create(CustomToolManifest(
            name: "可修复工具",
            description: "原始版本",
            implementation: .httpRead(CustomHTTPReadToolDefinition(allowedHosts: ["example.com"]))
        ))
        let replacement = CustomToolManifest(
            name: "另一个工具",
            description: "错误 ID",
            implementation: .httpRead(CustomHTTPReadToolDefinition(allowedHosts: ["example.com"]))
        )
        let proposal = ToolRepairProposal(
            toolID: saved.id,
            expectedVersion: saved.version,
            replacement: replacement,
            reason: "test"
        )
        do {
            _ = try await registry.applyRepair(proposal)
            Issue.record("修复 ID 不匹配时不应成功")
        } catch let error as CustomToolRegistryError {
            #expect(error == .replacementIDMismatch(expected: saved.id, actual: replacement.id))
        } catch {
            Issue.record("收到非预期错误：\(error)")
        }
    }

    @Test("Metrics are bounded and never include arguments")
    func metricsCollectorKeepsSafeTimingFacts() async {
        let collector = ToolMetricsCollector(capacity: 2)
        let first = ToolExecutionMetrics(
            runID: UUID(),
            callID: "call-1",
            toolName: "library_get_summary",
            discoveryMilliseconds: 1,
            executorMilliseconds: 2
        )
        await collector.record(first)
        await collector.record(ToolExecutionMetrics(runID: UUID(), callID: "call-2", toolName: "queue_get"))
        await collector.record(ToolExecutionMetrics(runID: UUID(), callID: "call-3", toolName: "playlist_list"))
        let snapshot = await collector.snapshot()
        #expect(snapshot.count == 2)
        #expect(snapshot.last?.toolName == "playlist_list")
        #expect(first.totalMilliseconds == 3)
    }
}
