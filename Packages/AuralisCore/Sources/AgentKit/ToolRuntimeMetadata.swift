import Foundation

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

public struct ToolDefinition: Sendable, Hashable, Identifiable {
    public var id: String { descriptor.name }
    public let descriptor: ToolDescriptor
    public let executor: ToolExecutorKind

    public init(descriptor: ToolDescriptor, executor: ToolExecutorKind) {
        self.descriptor = descriptor
        self.executor = executor
    }
}

public enum ToolCoverageIssue: Sendable, Equatable, Hashable {
    case duplicateCanonicalName(String)
    case aliasTargetMissing(alias: String, target: String)
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
        if requiresConfirmation { return .irreversibleDelete }
        return permission == .readOnly ? .none : .reversibleMutation
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
