import AIKit
import Domain
import Foundation
import LocalCatalog

/// The smallest authorization family a model request can explicitly open.
/// This is distinct from a provider-visible namespace and from the resource
/// lock used to serialize concurrent mutations.
public enum MutationScope: String, Codable, Sendable, Hashable, CaseIterable {
    case playback
    case queue
    case playlist
    case annotation
    case server
    case download
    case memory
    case customTool
}

/// Risk is a product property, not a synonym for the historical permission
/// enum. Only irreversible deletion requires the UI approval path.
public enum ToolRisk: String, Codable, Sendable, Hashable, CaseIterable {
    case none
    case reversibleMutation
    case irreversibleDelete
}

/// The only policy that can put a tool into the interactive approval path.
/// Authorization answers "may this operation run?"; this policy answers the
/// separate question "must a user explicitly approve it before it runs?".
/// Ordinary mutations therefore remain `.none` even when they require an
/// exact authorization operation.
public enum ToolConfirmationPolicy: Codable, Sendable, Equatable, Hashable {
    case none
    case explicitUserApproval(reason: String)

    public var requiresExplicitUserApproval: Bool {
        if case .explicitUserApproval = self { return true }
        return false
    }

    public var reason: String? {
        if case let .explicitUserApproval(reason) = self { return reason }
        return nil
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case reason
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "none":
            self = .none
        case "explicitUserApproval":
            self = .explicitUserApproval(reason: try container.decode(String.self, forKey: .reason))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "Unknown tool confirmation policy"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .none:
            try container.encode("none", forKey: .kind)
        case let .explicitUserApproval(reason):
            try container.encode("explicitUserApproval", forKey: .kind)
            try container.encode(reason, forKey: .reason)
        }
    }

    /// A workflow inherits the strictest confirmation policy of its children.
    /// This combines explicit policy declarations only; mutation, scope, and
    /// risk metadata never implicitly create an approval request.
    public static func mostRestrictive<S: Sequence>(_ policies: S) -> ToolConfirmationPolicy
    where S.Element == ToolConfirmationPolicy {
        policies.first(where: { $0.requiresExplicitUserApproval }) ?? .none
    }
}

public enum ToolExecutionProfile: String, Codable, Sendable, Hashable, CaseIterable {
    case localFast
    case localHeavy
    case networkRead
    case networkMutation
    case workflow

    public var timeout: TimeInterval {
        switch self {
        case .localFast: return 5
        case .localHeavy: return 15
        case .networkRead: return 30
        case .networkMutation: return 45
        case .workflow: return 180
        }
    }
}

/// Runtime dependencies passed to a canonical tool executor.  Keeping this
/// value separate from the task-local `ToolExecutionContext` lets a
/// `ToolDefinition` own both its metadata and its actual executable behavior
/// without widening every AgentBridge method.
public struct ToolExecutorContext: Sendable {
    public let bridge: any AgentBridge
    public let catalog: LocalCatalogStore
    public let serverID: ServerID?
    public let systemService: (any AgentSystemService)?
    public let externalMusicService: (any AgentExternalMusicService)?
    public let allowsLyrics: Bool
    public let allowsFavoritesAndRatings: Bool
    public let providerCapabilities: ModelCapabilities?
    public let webService: (any AgentWebService)?
    public let authorizationContext: SideEffectAuthorizationContext?
    public let activeSkillID: String?
    public let executionAuthority: ToolExecutionAuthority?
    public let executionLease: ToolExecutionLease
    public let resourceLeaseRegistry: MutationResourceLeaseRegistry
    public let recommendationIndexExecutionRegistry: RecommendationIndexExecutionRegistry
    public let customToolRegistry: CustomToolRegistry
    public let availableToolDescriptors: [ToolDescriptor]
    /// run-scoped Capability 环境快照（System Prompt / capabilities_get /
    /// 诊断共用同一份）。capabilities_get 直接消费，不再自行重新采集。
    public let capabilityEnvironment: AgentCapabilityEnvironment?

    public init(
        bridge: any AgentBridge,
        catalog: LocalCatalogStore,
        serverID: ServerID?,
        systemService: (any AgentSystemService)?,
        externalMusicService: (any AgentExternalMusicService)?,
        allowsLyrics: Bool,
        allowsFavoritesAndRatings: Bool = false,
        providerCapabilities: ModelCapabilities?,
        webService: (any AgentWebService)?,
        authorizationContext: SideEffectAuthorizationContext?,
        activeSkillID: String?,
        executionAuthority: ToolExecutionAuthority?,
        executionLease: ToolExecutionLease,
        resourceLeaseRegistry: MutationResourceLeaseRegistry,
        recommendationIndexExecutionRegistry: RecommendationIndexExecutionRegistry,
        customToolRegistry: CustomToolRegistry = .shared,
        availableToolDescriptors: [ToolDescriptor] = AgentToolRegistry.all,
        capabilityEnvironment: AgentCapabilityEnvironment? = nil
    ) {
        self.bridge = bridge
        self.catalog = catalog
        self.serverID = serverID
        self.systemService = systemService
        self.externalMusicService = externalMusicService
        self.allowsLyrics = allowsLyrics
        self.allowsFavoritesAndRatings = allowsFavoritesAndRatings
        self.providerCapabilities = providerCapabilities
        self.webService = webService
        self.authorizationContext = authorizationContext
        self.activeSkillID = activeSkillID
        self.executionAuthority = executionAuthority
        self.executionLease = executionLease
        self.resourceLeaseRegistry = resourceLeaseRegistry
        self.recommendationIndexExecutionRegistry = recommendationIndexExecutionRegistry
        self.customToolRegistry = customToolRegistry
        self.availableToolDescriptors = availableToolDescriptors
        self.capabilityEnvironment = capabilityEnvironment
    }

    /// Execute a child canonical call from a declarative tool.  The child
    /// stays inside the same authorization, run lease and resource registry;
    /// it cannot silently obtain a broader privilege than its parent.
    public func executeChild(_ call: ToolCall) async -> ToolResult {
        await ToolRuntime.execute(
            call,
            bridge: bridge,
            catalog: catalog,
            serverID: serverID,
            systemService: systemService,
            externalMusicService: externalMusicService,
            allowsLyrics: allowsLyrics,
            allowsFavoritesAndRatings: allowsFavoritesAndRatings,
            providerCapabilities: providerCapabilities,
            webService: webService,
            authorizationContext: authorizationContext,
            activeSkillID: activeSkillID,
            executionAuthority: executionAuthority,
            executionLease: executionLease,
            resourceLeaseRegistry: resourceLeaseRegistry,
            recommendationIndexExecutionRegistry: recommendationIndexExecutionRegistry,
            customToolRegistry: customToolRegistry,
            availableToolDescriptors: availableToolDescriptors,
            capabilityEnvironment: capabilityEnvironment
        )
    }

    public func withAdditionalAuthorizationOperations(_ operations: Set<ToolAuthorizationOperation>) -> ToolExecutorContext {
        ToolExecutorContext(
            bridge: bridge,
            catalog: catalog,
            serverID: serverID,
            systemService: systemService,
            externalMusicService: externalMusicService,
            allowsLyrics: allowsLyrics,
            allowsFavoritesAndRatings: allowsFavoritesAndRatings,
            providerCapabilities: providerCapabilities,
            webService: webService,
            authorizationContext: authorizationContext?.granting(operations: operations),
            activeSkillID: activeSkillID,
            executionAuthority: executionAuthority,
            executionLease: executionLease,
            resourceLeaseRegistry: resourceLeaseRegistry,
            recommendationIndexExecutionRegistry: recommendationIndexExecutionRegistry,
            customToolRegistry: customToolRegistry,
            availableToolDescriptors: availableToolDescriptors,
            capabilityEnvironment: capabilityEnvironment
        )
    }

    @available(*, deprecated, message: "Use withAdditionalAuthorizationOperations(_:)")
    public func withAdditionalAuthorizationScopes(_ scopes: Set<MutationScope>) -> ToolExecutorContext {
        _ = scopes
        return self
    }

    /// Execute an existing built-in implementation while it is being migrated
    /// out of the compatibility dispatcher.  New tools should provide their
    /// own closure instead of adding another switch case.
    public func executeLegacy(_ call: ToolCall, descriptor: ToolDescriptor) async -> ToolResult {
        await AgentToolRegistry.executeLegacy(
            call,
            descriptor: descriptor,
            context: self
        )
    }
}

public typealias ToolDefinitionExecutor = @Sendable (ToolExecutorContext, ToolCall) async -> ToolResult

/// Discovery metadata is derived from the canonical descriptor. ToolSelector
/// may rank it, but it no longer needs a second registry of tool-name arrays.
public struct ToolDiscoveryMetadata: Codable, Sendable, Hashable {
    public let intents: Set<String>
    public let capabilities: Set<String>
    public let keywords: Set<String>
    public let priority: Int

    public init(
        intents: Set<String>,
        capabilities: Set<String>,
        keywords: Set<String>,
        priority: Int = 0
    ) {
        self.intents = intents
        self.capabilities = capabilities
        self.keywords = keywords
        self.priority = priority
    }
}

/// The executor kind is deliberately explicit even while legacy switch
/// implementations are being migrated. A definition cannot exist without a
/// concrete runtime owner, so coverage tests can detect metadata-only tools.
public enum ToolExecutorKind: String, Codable, Sendable, Hashable {
    case catalog
    case web
    case systemService
    case agentBridge
    case recommendationSkill
    case legacyCompatibility
}

public struct ToolDefinition: Sendable, Identifiable {
    public var id: String { descriptor.name }
    public let descriptor: ToolDescriptor
    public let executorKind: ToolExecutorKind
    public let executor: ToolDefinitionExecutor

    public init(
        descriptor: ToolDescriptor,
        executorKind: ToolExecutorKind,
        executor: @escaping ToolDefinitionExecutor
    ) {
        self.descriptor = descriptor
        self.executorKind = executorKind
        self.executor = executor
    }

    /// Compatibility initializer for metadata-only callers.  Registry
    /// definitions use the closure initializer above; this fallback is kept
    /// so old integrations fail explicitly rather than silently bypassing the
    /// unified executor path.
    public init(descriptor: ToolDescriptor, executor: ToolExecutorKind) {
        self.init(descriptor: descriptor, executorKind: executor) { _, call in
            ToolResult(
                call: call,
                permission: descriptor.permission,
                success: false,
                summary: "工具 \(descriptor.name) 尚未绑定执行器。"
            )
        }
    }
}

public enum ToolCoverageIssue: Sendable, Equatable, Hashable {
    case duplicateCanonicalName(String)
    case aliasTargetMissing(alias: String, target: String)
    case emptyAlias(target: String)
    case invalidAlias(alias: String, target: String)
    case aliasCanonicalConflict(alias: String, target: String)
    case duplicateAlias(alias: String, targets: [String])
    case aliasLookupMismatch(alias: String, expected: String, actual: String?)
    case modelMutationMissingOperation(String)
    case modelMutationMissingScope(String)
    case irreversibleDeleteMissingApproval(String)
    case missingExecutor(String)
}

public struct ToolCoverageAudit: Sendable, Equatable {
    public let issues: [ToolCoverageIssue]

    public init(issues: [ToolCoverageIssue]) {
        self.issues = issues
    }

    public var isClean: Bool { issues.isEmpty }
}

extension ToolDescriptor {
    /// Compact infrastructure tools are marked by descriptor metadata so the
    /// selector does not maintain a parallel list of names.
    public var isCoreInfrastructure: Bool {
        tags.contains { $0.lowercased() == "core" }
    }

    public var mutationScope: MutationScope? {
        if let operation = authorizationOperation, let scope = operation.mutationScope {
            return scope
        }
        if let scope = derivedMutationScopes.first {
            return scope
        }
        guard permission != .readOnly else { return nil }
        switch sideEffectPolicy {
        case .none: return .customTool
        case .playback: return .playback
        case .queue: return .queue
        case .playlist: return .playlist
        case .annotation: return .annotation
        case .server: return .server
        case .download: return .download
        case .memory: return .memory
        }
    }

    public var risk: ToolRisk {
        if let derivedRisk {
            return derivedRisk
        }
        if let declaredRisk {
            return declaredRisk
        }
        return permission == .readOnly ? .none : .reversibleMutation
    }

    public var mutationScopes: Set<MutationScope> {
        if !derivedMutationScopes.isEmpty {
            return derivedMutationScopes
        }
        guard let scope = mutationScope else { return [] }
        return [scope]
    }

    public var executionProfile: ToolExecutionProfile {
        if requiredSkillID != nil { return .workflow }
        if permission == .readOnly {
            return networkAccess ? .networkRead : .localFast
        }
        return networkAccess ? .networkMutation : .localHeavy
    }

    public var discoveryMetadata: ToolDiscoveryMetadata {
        var intents = Set([group.rawValue])
        var capabilities = Set([namespace, name])
        var keywords = Set(tags.map { $0.lowercased() })
        keywords.insert(summary.lowercased())

        if permission == .readOnly { intents.insert("read") }
        else { intents.insert("mutation") }
        if let operation = authorizationOperation {
            intents.insert(operation.rawValue)
            capabilities.insert(operation.rawValue)
        }
        if networkAccess { capabilities.insert("network") }
        return ToolDiscoveryMetadata(
            intents: intents,
            capabilities: capabilities,
            keywords: keywords,
            priority: permission == .readOnly ? 10 : 20
        )
    }
}
