// SPDX-License-Identifier: GPL-3.0-only
import AIKit
import Domain
import Foundation

/// A declarative value source used by a Custom Tool workflow.  Bindings are
/// intentionally finite and structural; a manifest cannot evaluate Swift,
/// JavaScript, shell commands, or arbitrary expressions inside the app.
public enum CustomToolBinding: Codable, Sendable, Hashable {
    case input(String)
    case previousResult(step: Int, field: String)

    private enum CodingKeys: String, CodingKey { case kind, key, step, field }
    private enum Kind: String, Codable { case input, previousResult }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .input:
            self = .input(try container.decode(String.self, forKey: .key))
        case .previousResult:
            self = .previousResult(
                step: try container.decode(Int.self, forKey: .step),
                field: try container.decode(String.self, forKey: .field)
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .input(key):
            try container.encode(Kind.input, forKey: .kind)
            try container.encode(key, forKey: .key)
        case let .previousResult(step, field):
            try container.encode(Kind.previousResult, forKey: .kind)
            try container.encode(step, forKey: .step)
            try container.encode(field, forKey: .field)
        }
    }
}

public struct CustomToolStep: Codable, Sendable, Hashable {
    public let tool: String
    public let arguments: [String: AIJSONValue]
    public let bindings: [String: CustomToolBinding]

    public init(
        tool: String,
        arguments: [String: AIJSONValue] = [:],
        bindings: [String: CustomToolBinding] = [:]
    ) {
        self.tool = tool
        self.arguments = arguments
        self.bindings = bindings
    }
}

public struct CustomHTTPReadToolDefinition: Codable, Sendable, Hashable {
    public let urlArgument: String
    public let allowedHosts: Set<String>
    public let maxCharacters: Int

    public init(
        urlArgument: String = "url",
        allowedHosts: Set<String> = [],
        maxCharacters: Int = 30_000
    ) {
        self.urlArgument = urlArgument
        self.allowedHosts = Set(allowedHosts.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        })
        self.maxCharacters = max(1_000, min(maxCharacters, 100_000))
    }
}

public enum CustomToolImplementation: Codable, Sendable, Hashable {
    case workflow(steps: [CustomToolStep])
    case httpRead(CustomHTTPReadToolDefinition)

    private enum CodingKeys: String, CodingKey { case kind, steps, definition }
    private enum Kind: String, Codable { case workflow, httpRead }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .workflow:
            self = .workflow(steps: try container.decode([CustomToolStep].self, forKey: .steps))
        case .httpRead:
            self = .httpRead(try container.decode(CustomHTTPReadToolDefinition.self, forKey: .definition))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .workflow(steps):
            try container.encode(Kind.workflow, forKey: .kind)
            try container.encode(steps, forKey: .steps)
        case let .httpRead(definition):
            try container.encode(Kind.httpRead, forKey: .kind)
            try container.encode(definition, forKey: .definition)
        }
    }
}

public struct CustomToolManifest: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public var name: String
    public var description: String
    public var inputSchema: AIJSONValue
    public var outputSchema: AIJSONValue?
    public var implementation: CustomToolImplementation
    public var version: Int
    public var enabled: Bool
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        description: String,
        inputSchema: AIJSONValue = .object(["type": .string("object")]),
        outputSchema: AIJSONValue? = nil,
        implementation: CustomToolImplementation,
        version: Int = 1,
        enabled: Bool = true,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.outputSchema = outputSchema
        self.implementation = implementation
        self.version = max(1, version)
        self.enabled = enabled
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var canonicalToolName: String {
        "custom_" + Self.slug(name)
    }

    private static func slug(_ raw: String) -> String {
        let allowed = raw.lowercased().unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) { return Character(String(scalar)) }
            return "_"
        }
        let value = String(allowed)
            .split(separator: "_")
            .joined(separator: "_")
        return value.isEmpty ? idFallback : value
    }

    private static let idFallback = "tool"
}

public enum CustomToolValidationIssue: Codable, Sendable, Equatable, Hashable, LocalizedError {
    case emptyName
    case invalidName
    case nameConflict(String)
    case invalidInputSchema
    case emptyWorkflow
    case tooManySteps
    case unknownChildTool(String)
    case legacyChildTool(String)
    case nestedCustomTool(String)
    case invalidBinding(String)
    case invalidHTTPArgument
    case missingHTTPHostAllowlist
    case unsafeHTTPHost(String)

    public var errorDescription: String? {
        switch self {
        case .emptyName: return "自建工具名称不能为空。"
        case .invalidName: return "自建工具名称只能包含字母、数字、下划线、短横线和中文。"
        case let .nameConflict(name): return "工具名称已存在：\(name)"
        case .invalidInputSchema: return "输入 schema 必须是 JSON object schema。"
        case .emptyWorkflow: return "workflow 至少需要一个步骤。"
        case .tooManySteps: return "workflow 步骤不能超过 32 个。"
        case let .unknownChildTool(name): return "workflow 引用了未知工具：\(name)"
        case let .legacyChildTool(name): return "workflow 不能直接引用 legacy 工具：\(name)"
        case let .nestedCustomTool(name): return "workflow 暂不允许嵌套自建工具：\(name)"
        case let .invalidBinding(value): return "workflow binding 无效：\(value)"
        case .invalidHTTPArgument: return "HTTP read 必须声明 URL 参数。"
        case .missingHTTPHostAllowlist: return "HTTP read 必须声明非空的 HTTPS 主机 allowlist。"
        case let .unsafeHTTPHost(host): return "HTTP read 不允许使用不安全主机：\(host)"
        }
    }
}

public struct CustomToolDerivedMetadata: Codable, Sendable, Equatable, Hashable {
    public let risk: ToolRisk
    /// Confirmation is inherited from exact child policy declarations, never
    /// inferred from a broad risk/permission family.
    public let confirmationPolicy: ToolConfirmationPolicy
    public let scopes: Set<MutationScope>
    /// Exact canonical operations performed by workflow children. Scopes are
    /// retained for resource/risk reporting, but authorization uses this set.
    public let operations: Set<ToolAuthorizationOperation>
    public let resources: Set<MutationResource>
    public let networkAccess: Bool
    public let idempotent: Bool
    public let parallelSafe: Bool

    public init(
        risk: ToolRisk,
        confirmationPolicy: ToolConfirmationPolicy = .none,
        scopes: Set<MutationScope>,
        operations: Set<ToolAuthorizationOperation> = [],
        resources: Set<MutationResource>,
        networkAccess: Bool,
        idempotent: Bool,
        parallelSafe: Bool
    ) {
        self.risk = risk
        self.confirmationPolicy = confirmationPolicy
        self.scopes = scopes
        self.operations = operations
        self.resources = resources
        self.networkAccess = networkAccess
        self.idempotent = idempotent
        self.parallelSafe = parallelSafe
    }
}

public struct ToolRepairProposal: Codable, Sendable, Equatable, Hashable {
    public let toolID: UUID
    public let expectedVersion: Int
    public let replacement: CustomToolManifest
    public let reason: String

    public init(toolID: UUID, expectedVersion: Int, replacement: CustomToolManifest, reason: String) {
        self.toolID = toolID
        self.expectedVersion = expectedVersion
        self.replacement = replacement
        self.reason = reason
    }
}

public struct ToolDoctorReport: Codable, Sendable, Equatable, Hashable {
    public let toolName: String
    public let definitionVersion: Int?
    public let schema: AIJSONValue?
    public let failure: ToolFailureEnvelope?
    public let executor: String
    public let possibleFix: String

    public init(
        toolName: String,
        definitionVersion: Int?,
        schema: AIJSONValue?,
        failure: ToolFailureEnvelope?,
        executor: String,
        possibleFix: String
    ) {
        self.toolName = toolName
        self.definitionVersion = definitionVersion
        self.schema = schema
        self.failure = failure
        self.executor = executor
        self.possibleFix = possibleFix
    }
}

/// Atomic run-boundary view of the enabled declarative tools.  The revision
/// lets ToolLoop refresh the descriptor set after a builder mutation without
/// observing a mismatched revision and descriptor list.
public struct CustomToolRegistrySnapshot: Sendable, Equatable {
    public let revision: UInt64
    public let descriptors: [ToolDescriptor]

    public init(revision: UInt64, descriptors: [ToolDescriptor]) {
        self.revision = revision
        self.descriptors = descriptors
    }
}

/// Versioned, persisted registry for safe declarative tools.  The actor owns
/// all mutations and retains prior versions so a bad update can be rolled
/// back without modifying the signed app or executing generated code.
public actor CustomToolRegistry {
    public static let shared = CustomToolRegistry(storageURL: defaultStorageURL())

    private struct StoredState: Codable {
        var versions: [UUID: [CustomToolManifest]]
        var revision: UInt64?
    }

    private let storageURL: URL?
    private var versions: [UUID: [CustomToolManifest]]
    private var revision: UInt64

    public init(storageURL: URL? = nil) {
        self.storageURL = storageURL
        if let storageURL,
           let data = try? Data(contentsOf: storageURL),
           let state = try? JSONDecoder().decode(StoredState.self, from: data) {
            self.versions = state.versions
            self.revision = state.revision ?? 0
        } else {
            self.versions = [:]
            self.revision = 0
        }
    }

    public func list(enabledOnly: Bool = false) -> [CustomToolManifest] {
        versions.values
            .compactMap { $0.max(by: { $0.version < $1.version }) }
            .filter { !enabledOnly || $0.enabled }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func manifest(id: UUID) -> CustomToolManifest? {
        versions[id]?.max(by: { $0.version < $1.version })
    }

    public func manifest(named name: String) -> CustomToolManifest? {
        let needle = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return list().first { manifest in
            manifest.name.lowercased() == needle || manifest.canonicalToolName.lowercased() == needle
        }
    }

    public func history(id: UUID) -> [CustomToolManifest] {
        versions[id, default: []].sorted { $0.version < $1.version }
    }

    public func modelDescriptors() -> [ToolDescriptor] {
        list(enabledOnly: true).compactMap { materialize($0) }
    }

    public func currentRevision() -> UInt64 {
        revision
    }

    public func modelSnapshot() -> CustomToolRegistrySnapshot {
        CustomToolRegistrySnapshot(revision: revision, descriptors: modelDescriptors())
    }

    public func descriptor(named name: String) -> ToolDescriptor? {
        guard let manifest = manifest(named: name), manifest.enabled else { return nil }
        return materialize(manifest)
    }

    public func validate(_ manifest: CustomToolManifest) -> [CustomToolValidationIssue] {
        var issues = Self.validateShape(manifest)
        if case let .workflow(steps) = manifest.implementation {
            for step in steps where self.manifest(named: step.tool) != nil {
                issues.removeAll { $0 == .unknownChildTool(step.tool) }
                issues.append(.nestedCustomTool(step.tool))
            }
        }
        if let existing = AgentToolRegistry.descriptor(for: manifest.canonicalToolName), existing.customToolID == nil {
            issues.append(.nameConflict(manifest.canonicalToolName))
        }
        if let existing = list().first(where: {
            $0.id != manifest.id && $0.canonicalToolName == manifest.canonicalToolName
        }) {
            issues.append(.nameConflict(existing.canonicalToolName))
        }
        return Array(Set(issues))
    }

    @discardableResult
    public func create(_ manifest: CustomToolManifest) throws -> CustomToolManifest {
        let normalized = normalizedManifest(manifest, version: 1)
        let issues = validate(normalized)
        guard issues.isEmpty else { throw CustomToolRegistryError.invalid(issues) }
        var nextVersions = versions
        nextVersions[normalized.id] = [normalized]
        try persist(nextVersions)
        versions = nextVersions
        revision &+= 1
        return normalized
    }

    @discardableResult
    public func update(_ manifest: CustomToolManifest) throws -> CustomToolManifest {
        guard let current = self.manifest(id: manifest.id) else {
            throw CustomToolRegistryError.notFound(manifest.id)
        }
        let next = normalizedManifest(manifest, version: current.version + 1, createdAt: current.createdAt)
        let issues = validate(next)
        guard issues.isEmpty else { throw CustomToolRegistryError.invalid(issues) }
        var nextVersions = versions
        nextVersions[manifest.id, default: []].append(next)
        try persist(nextVersions)
        versions = nextVersions
        revision &+= 1
        return next
    }

    @discardableResult
    public func rollback(id: UUID, toVersion: Int) throws -> CustomToolManifest {
        guard let source = versions[id]?.first(where: { $0.version == toVersion }) else {
            throw CustomToolRegistryError.versionNotFound(id, toVersion)
        }
        return try update(source)
    }

    @discardableResult
    public func setEnabled(id: UUID, enabled: Bool) throws -> CustomToolManifest {
        guard let current = manifest(id: id) else { throw CustomToolRegistryError.notFound(id) }
        guard current.enabled != enabled else { return current }
        var next = current
        next.enabled = enabled
        return try update(next)
    }

    public func delete(id: UUID) throws {
        guard versions[id] != nil else { throw CustomToolRegistryError.notFound(id) }
        var nextVersions = versions
        nextVersions[id] = nil
        try persist(nextVersions)
        versions = nextVersions
        revision &+= 1
    }

    public func derivedMetadata(for manifest: CustomToolManifest) -> CustomToolDerivedMetadata {
        Self.derivedMetadata(manifest)
    }

    public func execute(
        _ call: ToolCall,
        descriptor: ToolDescriptor,
        context: ToolExecutorContext
    ) async -> ToolResult {
        guard let id = descriptor.customToolID, let manifest = manifest(id: id), manifest.enabled else {
            return Self.failure(call, descriptor, code: "custom_tool_unavailable", details: [:])
        }
        let childContext = context.withAdditionalAuthorizationOperations(descriptor.derivedAuthorizationOperations)
        switch manifest.implementation {
        case let .workflow(steps):
            var results: [ToolResult] = []
            var summaries: [String] = []
            var indeterminate = false
            for (index, step) in steps.enumerated() {
                guard let childDescriptor = AgentToolRegistry.descriptor(for: step.tool), childDescriptor.customToolID == nil else {
                    return Self.failure(call, descriptor, code: "custom_child_unavailable", details: [
                        "step": .number(Double(index)),
                        "tool": .string(step.tool),
                    ], indeterminate: indeterminate)
                }
                let arguments = Self.resolveArguments(
                    step.arguments,
                    bindings: step.bindings,
                    input: call.arguments,
                    previousResults: results
                )
                let result = await childContext.executeChild(ToolCall(name: childDescriptor.name, arguments: arguments))
                results.append(result)
                summaries.append("\(childDescriptor.name)：\(result.summary)")
                if result.permission != .readOnly, result.success || result.hasIndeterminateSideEffect {
                    indeterminate = true
                }
                guard result.success else {
                    return Self.failure(
                        call,
                        descriptor,
                        code: "custom_step_failed",
                        details: [
                            "step": .number(Double(index)),
                            "tool": .string(childDescriptor.name),
                            "childCode": result.failure.map { .string($0.code) } ?? .null,
                        ],
                        indeterminate: indeterminate,
                        summary: "自建工具《\(manifest.name)》在第 \(index + 1) 步失败：\(result.summary)"
                    )
                }
            }
            return ToolResult(
                call: call,
                permission: descriptor.permission,
                success: true,
                summary: "已执行自建工具《\(manifest.name)》：" + summaries.joined(separator: "；"),
                facts: ["customToolID": manifest.id.uuidString, "customToolVersion": String(manifest.version)],
                hasIndeterminateSideEffect: false
            )
        case let .httpRead(definition):
            guard let webService = context.webService,
                  let rawURL = call.arguments[definition.urlArgument].flatMap(Self.stringValue),
                  let url = URL(string: rawURL),
                  let host = url.host?.lowercased() else {
                return Self.failure(call, descriptor, code: "custom_http_invalid_url", details: [:])
            }
            guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil else {
                return Self.failure(call, descriptor, code: "custom_http_insecure_url", details: ["host": .string(host)])
            }
            guard !definition.allowedHosts.isEmpty else {
                return Self.failure(call, descriptor, code: "custom_http_host_allowlist_missing", details: ["host": .string(host)])
            }
            if !definition.allowedHosts.contains(host) {
                return Self.failure(call, descriptor, code: "custom_http_host_not_allowed", details: ["host": .string(host)])
            }
            do {
                let document = try await webService.fetch(url: url)
                let text = String(document.text.prefix(definition.maxCharacters))
                return ToolResult(
                    call: call,
                    permission: .readOnly,
                    success: true,
                    summary: "已读取自建工具网页：\(document.source.title)",
                    payload: .text("来源：\(document.source.title)\n\n\(text)"),
                    trustLevel: .externalUntrusted
                )
            } catch {
                return Self.failure(call, descriptor, code: "custom_http_read_failed", details: [:], summary: "自建工具网页读取失败：\(error.localizedDescription)")
            }
        }
    }

    public func diagnose(
        toolName: String,
        failure: ToolFailureEnvelope? = nil
    ) -> ToolDoctorReport {
        if let manifest = manifest(named: toolName), let descriptor = materialize(manifest) {
            return ToolDoctorReport(
                toolName: descriptor.name,
                definitionVersion: manifest.version,
                schema: manifest.inputSchema,
                failure: failure,
                executor: "CustomToolRegistry",
                possibleFix: failure?.retryable == true ? "按 failure.phase 重试或修正参数；更新会生成新版本。" : "检查 manifest 子步骤、schema 和权限范围；可回滚到旧版本。"
            )
        }
        if let descriptor = AgentToolRegistry.descriptor(for: toolName) {
            return ToolDoctorReport(
                toolName: descriptor.name,
                definitionVersion: nil,
                schema: .object(["name": .string(descriptor.name)]),
                failure: failure,
                executor: AgentToolRegistry.definition(for: descriptor.name)?.executorKind.rawValue ?? "unknown",
                possibleFix: "检查 canonical descriptor、结构化参数和 App Bridge 依赖。"
            )
        }
        return ToolDoctorReport(
            toolName: toolName,
            definitionVersion: nil,
            schema: nil,
            failure: failure,
            executor: "unknown",
            possibleFix: "先通过 tool_search 发现 canonical 工具。"
        )
    }

    public func applyRepair(_ proposal: ToolRepairProposal) throws -> CustomToolManifest {
        guard let current = manifest(id: proposal.toolID), current.version == proposal.expectedVersion else {
            throw CustomToolRegistryError.staleVersion(proposal.toolID, proposal.expectedVersion)
        }
        guard proposal.replacement.id == proposal.toolID else {
            throw CustomToolRegistryError.replacementIDMismatch(expected: proposal.toolID, actual: proposal.replacement.id)
        }
        return try update(proposal.replacement)
    }

    // MARK: - Builder tool entry points

    public func executeBuilder(
        _ call: ToolCall,
        descriptor: ToolDescriptor,
        context: ToolExecutorContext
    ) async -> ToolResult {
        do {
            switch call.name {
            case "tool_builder_list":
                let entries = list().map { "\($0.canonicalToolName) v\($0.version) · \($0.enabled ? "enabled" : "disabled") · \($0.description)" }
                return ToolResult(call: call, permission: descriptor.permission, success: true, summary: entries.isEmpty ? "还没有自建工具。" : entries.joined(separator: "\n"))
            case "tool_builder_inspect":
                guard let manifest = try resolveManifest(call) else { throw CustomToolRegistryError.missing("tool") }
                return ToolResult(call: call, permission: descriptor.permission, success: true, summary: "\(manifest.canonicalToolName) v\(manifest.version)\n\(manifest.description)\n\(manifest.inputSchema.jsonString)")
            case "tool_builder_validate":
                guard let manifest = try resolveManifest(call) else { throw CustomToolRegistryError.missing("manifest") }
                let issues = validate(manifest)
                return ToolResult(call: call, permission: descriptor.permission, success: issues.isEmpty, summary: issues.isEmpty ? "自建工具校验通过。" : issues.map(\.localizedDescription).joined(separator: "\n"), failure: issues.isEmpty ? nil : ToolFailureEnvelope(toolName: call.name, phase: .inputValidation, code: "custom_manifest_invalid", retryable: false))
            case "tool_builder_test":
                guard let manifest = try resolveManifest(call) else { throw CustomToolRegistryError.missing("tool") }
                let issues = validate(manifest)
                guard issues.isEmpty else { throw CustomToolRegistryError.invalid(issues) }
                let metadata = Self.derivedMetadata(manifest)
                return ToolResult(call: call, permission: descriptor.permission, success: true, summary: "dry-run 通过：风险=\(metadata.risk.rawValue)，scope=\(metadata.scopes.map(\.rawValue).sorted().joined(separator: ","))，步骤/实现未真正执行。")
            case "tool_builder_create":
                let manifest = try manifestFrom(call, id: nil)
                let created = try create(manifest)
                return ToolResult(call: call, permission: descriptor.permission, success: true, summary: "已创建自建工具：\(created.canonicalToolName) v\(created.version)", facts: ["customToolID": created.id.uuidString])
            case "tool_builder_update":
                let manifest = try manifestFrom(call, id: try resolveManifest(call)?.id)
                let updated = try update(manifest)
                return ToolResult(call: call, permission: descriptor.permission, success: true, summary: "已更新自建工具：\(updated.canonicalToolName) v\(updated.version)", facts: ["customToolID": updated.id.uuidString])
            case "tool_builder_enable", "tool_builder_disable":
                let current = try requireManifest(call)
                let updated = try setEnabled(id: current.id, enabled: call.name == "tool_builder_enable")
                return ToolResult(call: call, permission: descriptor.permission, success: true, summary: "已\(updated.enabled ? "启用" : "停用")：\(updated.canonicalToolName) v\(updated.version)")
            case "tool_builder_delete":
                let current = try requireManifest(call)
                try delete(id: current.id)
                return ToolResult(call: call, permission: descriptor.permission, success: true, summary: "已删除自建工具：\(current.canonicalToolName)")
            case "tool_diagnose":
                let toolName = try call.string("toolName")
                let report = diagnose(toolName: toolName)
                return ToolResult(call: call, permission: descriptor.permission, success: true, summary: report.possibleFix)
            case "tool_repair":
                let proposal = try repairProposal(from: call)
                let updated = try applyRepair(proposal)
                return ToolResult(call: call, permission: descriptor.permission, success: true, summary: "已应用自建工具修复并生成版本 v\(updated.version)。")
            default:
                return ToolResult(call: call, permission: descriptor.permission, success: false, summary: "未知 Tool Builder 操作。")
            }
        } catch let error as CustomToolRegistryError {
            return ToolResult(call: call, permission: descriptor.permission, success: false, summary: error.localizedDescription, failure: ToolFailureEnvelope(toolName: call.name, phase: .inputValidation, code: error.code, retryable: false))
        } catch {
            return ToolResult(call: call, permission: descriptor.permission, success: false, summary: "自建工具操作失败：\(error.localizedDescription)", failure: ToolFailureEnvelope(toolName: call.name, phase: .execution, code: "custom_builder_failed", retryable: false))
        }
    }

    // MARK: - Materialization and validation

    private func materialize(_ manifest: CustomToolManifest) -> ToolDescriptor? {
        let issues = Self.validateShape(manifest)
        guard issues.isEmpty else { return nil }
        let metadata = Self.derivedMetadata(manifest)
        let permission: ToolPermission = switch metadata.risk {
        case .none: .readOnly
        case .reversibleMutation: .reversible
        case .irreversibleDelete: .destructive
        }
        let parameters = Self.parameters(from: manifest.inputSchema)
        let sideEffect: ToolSideEffectPolicy = {
            guard let scope = metadata.scopes.first else { return .none }
            switch scope {
            case .playback: return .playback
            case .queue: return .queue
            case .playlist: return .playlist
            case .annotation: return .annotation
            case .server: return .server
            case .download: return .download
            case .memory, .customTool: return .memory
            }
        }()
        return ToolDescriptor(
            name: manifest.canonicalToolName,
            group: .catalog,
            permission: permission,
            confirmationPolicy: metadata.confirmationPolicy,
            summary: manifest.description,
            parameters: parameters,
            sideEffectPolicy: sideEffect,
            evidencePolicy: permission == .readOnly ? ToolEvidencePolicy.externalAPI : ToolEvidencePolicy.none,
            defaultPresentationRole: .finalResult,
            namespace: "custom",
            tags: ["custom", manifest.name, manifest.canonicalToolName],
            outputSchemaJSON: manifest.outputSchema?.jsonString,
            idempotent: metadata.idempotent,
            parallelSafe: metadata.parallelSafe,
            networkAccess: metadata.networkAccess,
            visibility: .model,
            customToolID: manifest.id,
            customToolVersion: manifest.version,
            derivedMutationScopes: metadata.scopes,
            derivedMutationResources: metadata.resources,
            derivedAuthorizationOperations: metadata.operations,
            derivedRisk: metadata.risk
        )
    }

    private static func derivedMetadata(_ manifest: CustomToolManifest) -> CustomToolDerivedMetadata {
        var risk: ToolRisk = .none
        var confirmationPolicy: ToolConfirmationPolicy = .none
        var scopes = Set<MutationScope>()
        var operations = Set<ToolAuthorizationOperation>()
        var resources = Set<MutationResource>()
        var network = false
        var idempotent = true
        var parallel = true
        switch manifest.implementation {
        case let .workflow(steps):
            for step in steps {
                guard let descriptor = AgentToolRegistry.descriptor(for: step.tool) else { continue }
                risk = maxRisk(risk, descriptor.risk)
                confirmationPolicy = ToolConfirmationPolicy.mostRestrictive([
                    confirmationPolicy,
                    descriptor.confirmationPolicy,
                ])
                scopes.formUnion(descriptor.mutationScopes)
                if let operation = descriptor.authorizationOperation {
                    operations.insert(operation)
                }
                resources.formUnion(descriptor.mutationResources)
                network = network || descriptor.networkAccess
                idempotent = idempotent && descriptor.idempotent
                parallel = parallel && descriptor.parallelSafe
            }
        case .httpRead:
            network = true
        }
        return CustomToolDerivedMetadata(
            risk: risk,
            confirmationPolicy: confirmationPolicy,
            scopes: scopes,
            operations: operations,
            resources: resources,
            networkAccess: network,
            idempotent: idempotent,
            parallelSafe: parallel
        )
    }

    private static func maxRisk(_ lhs: ToolRisk, _ rhs: ToolRisk) -> ToolRisk {
        if lhs == .irreversibleDelete || rhs == .irreversibleDelete { return .irreversibleDelete }
        if lhs == .reversibleMutation || rhs == .reversibleMutation { return .reversibleMutation }
        return .none
    }

    private static func validateShape(_ manifest: CustomToolManifest) -> [CustomToolValidationIssue] {
        var issues: [CustomToolValidationIssue] = []
        let name = manifest.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { issues.append(.emptyName) }
        if name.count > 80 || name.contains(where: { $0.isWhitespace && $0 != " " }) { issues.append(.invalidName) }
        guard case let .object(schema) = manifest.inputSchema,
              stringValue(schema["type"]) == "object" || schema["type"] == nil else {
            issues.append(.invalidInputSchema)
            return issues
        }
        switch manifest.implementation {
        case let .workflow(steps):
            if steps.isEmpty { issues.append(.emptyWorkflow) }
            if steps.count > 32 { issues.append(.tooManySteps) }
            for step in steps {
                guard let descriptor = AgentToolRegistry.descriptor(for: step.tool) else {
                    issues.append(.unknownChildTool(step.tool))
                    continue
                }
                if descriptor.visibility == .legacyOnly { issues.append(.legacyChildTool(step.tool)) }
                if descriptor.customToolID != nil { issues.append(.nestedCustomTool(step.tool)) }
                for (argument, binding) in step.bindings {
                    switch binding {
                    case let .input(key) where key.isEmpty:
                        issues.append(.invalidBinding(argument))
                    case let .previousResult(stepIndex, field) where stepIndex < 0 || field.isEmpty:
                        issues.append(.invalidBinding(argument))
                    default: break
                    }
                }
            }
        case let .httpRead(definition):
            if definition.urlArgument.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append(.invalidHTTPArgument)
            }
            if definition.allowedHosts.isEmpty {
                issues.append(.missingHTTPHostAllowlist)
            }
            for host in definition.allowedHosts where host.contains("/") || host.contains(":") {
                issues.append(.unsafeHTTPHost(host))
            }
            for host in definition.allowedHosts where host == "localhost" || host.hasSuffix(".local") || Self.looksLikeIPv4(host) {
                issues.append(.unsafeHTTPHost(host))
            }
        }
        return Array(Set(issues))
    }

    private static func parameters(from schema: AIJSONValue) -> [ToolParameter] {
        guard case let .object(object) = schema,
              case let .object(properties) = object["properties"] else { return [] }
        let required: Set<String> = {
            guard case let .array(values) = object["required"] else { return [] }
            return Set(values.compactMap(stringValue))
        }()
        return properties.keys.sorted().map { name in
            let property = properties[name]
            let description: String
            if case let .object(raw) = property, let text = stringValue(raw["description"]) {
                description = text
            } else {
                description = "自建工具参数"
            }
            return ToolParameter(name: name, required: required.contains(name), description: description, schemaJSON: property?.jsonString)
        }
    }

    private func normalizedManifest(_ manifest: CustomToolManifest, version: Int, createdAt: Date? = nil) -> CustomToolManifest {
        CustomToolManifest(
            id: manifest.id,
            name: manifest.name.trimmingCharacters(in: .whitespacesAndNewlines),
            description: manifest.description.trimmingCharacters(in: .whitespacesAndNewlines),
            inputSchema: manifest.inputSchema,
            outputSchema: manifest.outputSchema,
            implementation: manifest.implementation,
            version: version,
            enabled: manifest.enabled,
            createdAt: createdAt ?? manifest.createdAt,
            updatedAt: .now
        )
    }

    private func resolveManifest(_ call: ToolCall) throws -> CustomToolManifest? {
        if let raw = call.arguments["manifest"], case .object = raw {
            return try Self.decodeManifest(raw, fallbackID: nil)
        }
        if let id = try? call.string("toolID"), let uuid = UUID(uuidString: id) {
            return manifest(id: uuid)
        }
        if let name = call.optionalString("tool"), let manifest = manifest(named: name) { return manifest }
        if let name = call.optionalString("name"), let manifest = manifest(named: name) { return manifest }
        return nil
    }

    private func requireManifest(_ call: ToolCall) throws -> CustomToolManifest {
        guard let manifest = try resolveManifest(call) else { throw CustomToolRegistryError.missing("tool") }
        return manifest
    }

    private func manifestFrom(_ call: ToolCall, id: UUID?) throws -> CustomToolManifest {
        guard let raw = call.arguments["manifest"], case .object = raw else {
            throw CustomToolRegistryError.missing("manifest")
        }
        return try Self.decodeManifest(raw, fallbackID: id)
    }

    private func repairProposal(from call: ToolCall) throws -> ToolRepairProposal {
        guard let raw = call.arguments["proposal"], case let .object(object) = raw,
              let idString = Self.stringValue(object["toolID"]), let id = UUID(uuidString: idString),
              let expected = Self.intValue(object["expectedVersion"]),
              let replacement = object["replacement"], case .object = replacement else {
            throw CustomToolRegistryError.missing("proposal")
        }
        return ToolRepairProposal(
            toolID: id,
            expectedVersion: expected,
            replacement: try Self.decodeManifest(replacement, fallbackID: id),
            reason: Self.stringValue(object["reason"]) ?? "runtime repair"
        )
    }

    private static func decodeManifest(_ value: AIJSONValue, fallbackID: UUID?) throws -> CustomToolManifest {
        guard case let .object(object) = value,
              let name = stringValue(object["name"]),
              let description = stringValue(object["description"]),
              let inputSchema = object["inputSchema"],
              let implementationValue = object["implementation"] else {
            throw CustomToolRegistryError.missing("manifest fields")
        }
        let implementation = try JSONDecoder().decode(CustomToolImplementation.self, from: implementationValue.jsonData)
        let id = stringValue(object["id"]).flatMap(UUID.init(uuidString:)) ?? fallbackID ?? UUID()
        let version = intValue(object["version"]) ?? 1
        let enabled = boolValue(object["enabled"]) ?? true
        return CustomToolManifest(
            id: id,
            name: name,
            description: description,
            inputSchema: inputSchema,
            outputSchema: object["outputSchema"],
            implementation: implementation,
            version: version,
            enabled: enabled
        )
    }

    private static func resolveArguments(
        _ arguments: [String: AIJSONValue],
        bindings: [String: CustomToolBinding],
        input: [String: AIJSONValue],
        previousResults: [ToolResult]
    ) -> [String: AIJSONValue] {
        var resolved = arguments
        for (key, binding) in bindings {
            switch binding {
            case let .input(inputKey):
                resolved[key] = input[inputKey] ?? .null
            case let .previousResult(step, field):
                guard previousResults.indices.contains(step) else { resolved[key] = .null; continue }
                let result = previousResults[step]
                switch field {
                case "summary": resolved[key] = .string(result.summary)
                case "success": resolved[key] = .bool(result.success)
                default: resolved[key] = result.facts[field].map(AIJSONValue.string) ?? .null
                }
            }
        }
        return resolved.mapValues { value in
            guard case let .string(text) = value else { return value }
            if text.hasPrefix("$input.") {
                return input[String(text.dropFirst(7))] ?? value
            }
            return value
        }
    }

    private static func stringValue(_ value: AIJSONValue?) -> String? {
        guard case let .string(value) = value else { return nil }
        return value
    }

    private static func intValue(_ value: AIJSONValue?) -> Int? {
        switch value {
        case let .number(value) where value.rounded() == value: return Int(value)
        case let .string(value): return Int(value)
        default: return nil
        }
    }

    private static func boolValue(_ value: AIJSONValue?) -> Bool? {
        guard case let .bool(value) = value else { return nil }
        return value
    }

    private static func looksLikeIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { part in
            !part.isEmpty && part.allSatisfy(\.isNumber) && Int(part) != nil
        }
    }

    private static func failure(
        _ call: ToolCall,
        _ descriptor: ToolDescriptor,
        code: String,
        details: [String: AIJSONValue],
        indeterminate: Bool = false,
        summary: String? = nil
    ) -> ToolResult {
        ToolResult(
            call: call,
            permission: descriptor.permission,
            success: false,
            summary: summary ?? "自建工具执行失败：\(code)",
            hasIndeterminateSideEffect: indeterminate,
            failure: ToolFailureEnvelope(toolName: descriptor.name, phase: .execution, code: code, retryable: false, safeDetails: details)
        )
    }

    private static func defaultStorageURL() -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return base.appendingPathComponent("Auralis", isDirectory: true).appendingPathComponent("custom-tools.json")
    }

    private func persist(_ state: [UUID: [CustomToolManifest]]) throws {
        // A nil URL is the explicit in-memory/test configuration. A concrete
        // URL, however, is a durability contract: encode/write failures must
        // reach the caller before the actor swaps its in-memory state.
        guard let storageURL else { return }
        do {
            try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(StoredState(versions: state, revision: revision &+ 1))
            try data.write(to: storageURL, options: .atomic)
        } catch {
            throw CustomToolRegistryError.persistenceFailed
        }
    }
}

public enum CustomToolRegistryError: Error, LocalizedError, Sendable, Equatable {
    case invalid([CustomToolValidationIssue])
    case notFound(UUID)
    case versionNotFound(UUID, Int)
    case staleVersion(UUID, Int)
    case replacementIDMismatch(expected: UUID, actual: UUID)
    case missing(String)
    case persistenceFailed

    public var code: String {
        switch self {
        case .invalid: return "custom_manifest_invalid"
        case .notFound: return "custom_tool_not_found"
        case .versionNotFound: return "custom_version_not_found"
        case .staleVersion: return "custom_version_conflict"
        case .replacementIDMismatch: return "custom_repair_id_mismatch"
        case .missing: return "custom_argument_missing"
        case .persistenceFailed: return "custom_persistence_failed"
        }
    }

    public var errorDescription: String? {
        switch self {
        case let .invalid(issues): return issues.map(\.localizedDescription).joined(separator: "\n")
        case let .notFound(id): return "找不到自建工具：\(id.uuidString)"
        case let .versionNotFound(id, version): return "找不到自建工具版本：\(id.uuidString) v\(version)"
        case let .staleVersion(id, version): return "自建工具版本已变化：\(id.uuidString) 期望 v\(version)"
        case let .replacementIDMismatch(expected, actual): return "修复 proposal 的工具 ID 不匹配：期望 \(expected.uuidString)，实际 \(actual.uuidString)"
        case let .missing(name): return "缺少参数：\(name)"
        case .persistenceFailed: return "自建工具未能安全保存；本次修改未生效。"
        }
    }
}

/// Public façade used by future UI and tests.  It keeps manifest operations
/// separate from the Agent tool protocol while sharing the same registry.
public enum ToolBuilder {
    public static func validate(_ manifest: CustomToolManifest) async -> [CustomToolValidationIssue] {
        await CustomToolRegistry.shared.validate(manifest)
    }

    public static func create(_ manifest: CustomToolManifest) async throws -> CustomToolManifest {
        try await CustomToolRegistry.shared.create(manifest)
    }

    public static func update(_ manifest: CustomToolManifest) async throws -> CustomToolManifest {
        try await CustomToolRegistry.shared.update(manifest)
    }

    public static func rollback(id: UUID, toVersion: Int) async throws -> CustomToolManifest {
        try await CustomToolRegistry.shared.rollback(id: id, toVersion: toVersion)
    }
}
