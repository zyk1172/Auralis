import Foundation

/// Public, compact description returned by `tool_search`.  It intentionally
/// omits the full schema; the runtime can add the selected descriptor to the
/// next provider request without making discovery results consume the whole
/// conversation context.
public struct ToolCatalogEntry: Codable, Hashable, Sendable, Identifiable {
    public var id: String { name }
    public let name: String
    public let namespace: String
    public let summary: String
    public let sideEffect: ToolSideEffectPolicy
    public let networkAccess: Bool
    public let parallelSafe: Bool
    public let tags: [String]

    public init(descriptor: ToolDescriptor) {
        self.name = descriptor.name
        self.namespace = descriptor.namespace
        self.summary = descriptor.summary
        self.sideEffect = descriptor.sideEffectPolicy
        self.networkAccess = descriptor.networkAccess
        self.parallelSafe = descriptor.parallelSafe
        self.tags = descriptor.tags
    }
}

/// The single searchable source of truth for registered tool capabilities.
/// ToolSelector may rank a shortlist, but it must use this catalog for
/// discovery and never invent a capability from keyword switches.
public struct ToolCatalog: Sendable {
    public let descriptors: [ToolDescriptor]

    public init(descriptors: [ToolDescriptor] = AgentToolRegistry.all) {
        self.descriptors = descriptors
    }

    public func descriptor(named name: String) -> ToolDescriptor? {
        let normalized = name.lowercased()
        return descriptors.first { descriptor in
            descriptor.name.lowercased() == normalized
                || descriptor.aliases.contains(where: { $0.lowercased() == normalized })
        }
    }

    public func search(query: String, namespace: String? = nil, limit: Int = 8) -> [ToolCatalogEntry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let namespaceNeedle = namespace?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered = descriptors.filter { descriptor in
            guard namespaceNeedle.map({ descriptor.namespace.lowercased() == $0 }) ?? true else { return false }
            guard !needle.isEmpty else { return true }
            return descriptor.name.lowercased().contains(needle)
                || descriptor.namespace.lowercased().contains(needle)
                || descriptor.summary.lowercased().contains(needle)
                || descriptor.tags.joined(separator: " ").lowercased().contains(needle)
        }
        return filtered
            .sorted { lhs, rhs in
                score(lhs, needle: needle) > score(rhs, needle: needle)
            }
            .prefix(min(max(limit, 1), 50))
            .map(ToolCatalogEntry.init)
    }

    private func score(_ descriptor: ToolDescriptor, needle: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var result = 0
        if descriptor.name.lowercased() == needle { result += 100 }
        if descriptor.name.lowercased().hasPrefix(needle) { result += 40 }
        if descriptor.namespace.lowercased() == needle { result += 20 }
        if descriptor.tags.contains(where: { $0.lowercased() == needle }) { result += 15 }
        if descriptor.summary.lowercased().contains(needle) { result += 5 }
        return result
    }
}
