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

/// A derived capability inventory for diagnostics and the App's capability
/// screen. It is intentionally computed from canonical descriptors, so adding
/// a tool cannot silently create a second hand-maintained capability list.
public struct ToolCapabilityCoverage: Codable, Hashable, Sendable, Identifiable {
    public var id: String { namespace }
    public let namespace: String
    public let toolNames: [String]
    public let readOnlyCount: Int
    public let mutationCount: Int
    public let networkCount: Int

    public init(
        namespace: String,
        toolNames: [String],
        readOnlyCount: Int,
        mutationCount: Int,
        networkCount: Int
    ) {
        self.namespace = namespace
        self.toolNames = toolNames
        self.readOnlyCount = readOnlyCount
        self.mutationCount = mutationCount
        self.networkCount = networkCount
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

    /// Returns only model-visible canonical capabilities. Legacy and
    /// internal/skill-only descriptors stay executable through Runtime but do
    /// not appear in the App-facing capability inventory.
    public func capabilityCoverage() -> [ToolCapabilityCoverage] {
        let grouped = Dictionary(grouping: descriptors.filter { $0.visibility == .model }, by: \.namespace)
        return grouped.keys.sorted().compactMap { namespace in
            guard let descriptors = grouped[namespace] else { return nil }
            let names = descriptors.map(\.name).sorted()
            return ToolCapabilityCoverage(
                namespace: namespace,
                toolNames: names,
                readOnlyCount: descriptors.filter { $0.permission == .readOnly }.count,
                mutationCount: descriptors.filter { $0.permission != .readOnly }.count,
                networkCount: descriptors.filter(\.networkAccess).count
            )
        }
    }

    public func search(
        query: String,
        namespace: String? = nil,
        limit: Int = 8,
        activeSkillID: String? = nil
    ) -> [ToolCatalogEntry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let namespaceNeedle = namespace?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered = descriptors.filter { descriptor in
            guard descriptor.isVisible(toSkillID: activeSkillID) else { return false }
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
