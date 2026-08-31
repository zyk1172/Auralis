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
    /// Semantic contracts are compact model-facing hints.  The full JSON
    /// schema remains loaded only when Runtime selects this tool.
    public let semanticInputs: [String]
    public let semanticOutputs: [String]
    public let permission: ToolPermission
    /// Canonical operation metadata（无副作用时为 nil），用于路由和诊断。
    public let authorizationOperation: String?
    /// Legacy compatibility field. Local reversible tools are not hidden behind
    /// an operation allow-list, so current catalog responses leave this nil.
    public let authorized: Bool?

    public init(descriptor: ToolDescriptor) {
        self.init(descriptor: descriptor, authorized: nil)
    }

    public init(descriptor: ToolDescriptor, authorized: Bool?) {
        self.name = descriptor.name
        self.namespace = descriptor.namespace
        self.summary = descriptor.summary
        self.sideEffect = descriptor.sideEffectPolicy
        self.networkAccess = descriptor.networkAccess
        self.parallelSafe = descriptor.parallelSafe
        self.tags = descriptor.tags
        self.semanticInputs = descriptor.semanticInputs.isEmpty
            ? descriptor.parameters.map(\.name)
            : descriptor.semanticInputs
        self.semanticOutputs = descriptor.semanticOutputs
        self.permission = descriptor.permission
        self.authorizationOperation = descriptor.authorizationOperation?.rawValue
        self.authorized = authorized
    }
}

/// A compact, model-facing directory row derived from the canonical
/// `ToolDescriptor`.  This is awareness, not an executable schema and never
/// grants a capability to the model.
public struct ToolAwarenessEntry: Sendable, Hashable, Identifiable {
    public enum Availability: Sendable, Hashable {
        case available
        case degraded(String)
        case unavailable(String)

        var description: String {
            switch self {
            case .available: "可用"
            case let .degraded(reason): "降级：\(reason)"
            case let .unavailable(reason): "不可用：\(reason)"
            }
        }
    }

    public var id: String { name }
    public let name: String
    public let namespace: String
    /// `ToolDescriptor.summary` is the canonical model-facing purpose.
    public let purpose: String
    public let permission: ToolPermission
    public let semanticInputs: [String]
    public let semanticOutputs: [String]
    public let availability: Availability
    /// Legacy compatibility field. Risk and visible confirmation policy are
    /// the only execution distinctions; operation metadata is not a grant.
    public let authorized: Bool?

    init(
        descriptor: ToolDescriptor,
        environment: AgentCapabilityEnvironment,
        authorizedOperations: Set<ToolAuthorizationOperation>?
    ) {
        name = descriptor.name
        namespace = descriptor.namespace
        purpose = descriptor.summary
        permission = descriptor.permission
        semanticInputs = descriptor.semanticInputs.isEmpty
            ? descriptor.parameters.map(\.name)
            : descriptor.semanticInputs
        semanticOutputs = descriptor.semanticOutputs
        availability = Self.availability(for: descriptor, environment: environment)
        _ = authorizedOperations
        authorized = nil
    }

    private static func availability(
        for descriptor: ToolDescriptor,
        environment: AgentCapabilityEnvironment
    ) -> Availability {
        if descriptor.group == .server, !environment.activeServer {
            return .degraded("未连接音乐服务器")
        }
        if descriptor.name == "web_search", !environment.webSearchAvailable {
            return .unavailable("联网搜索未配置")
        }
        if descriptor.name == "web_fetch", !environment.webFetchAvailable {
            return .unavailable("网页读取未配置")
        }
        if descriptor.group == .download, !environment.downloadServiceAvailable {
            return .unavailable("下载服务不可用")
        }
        if descriptor.group == .memory, !environment.systemServiceAvailable {
            return .degraded("系统服务不可用")
        }
        return .available
    }

    var renderedLine: String {
        let inputs = semanticInputs.isEmpty ? "无" : semanticInputs.joined(separator: "、")
        let outputs = semanticOutputs.isEmpty ? "结果" : semanticOutputs.joined(separator: "、")
        return "- \(name)：\(purpose)。输入：\(inputs)；输出：\(outputs)；权限：\(permissionLabel)；状态：\(availability.description)"
    }

    private var permissionLabel: String {
        switch permission {
        case .readOnly: "只读"
        case .reversible: "可逆修改"
        case .destructive: "不可逆修改"
        }
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

    /// Complete model awareness directory.  It intentionally filters by
    /// visibility but does not filter mutations by semantic operation: a model
    /// must know a capability exists. Internal/legacy names never enter this
    /// directory.
    public func awarenessEntries(
        activeSkillID: String? = nil,
        environment: AgentCapabilityEnvironment,
        authorizedOperations: Set<ToolAuthorizationOperation>? = nil
    ) -> [ToolAwarenessEntry] {
        descriptors
            .filter { $0.isVisible(toSkillID: activeSkillID) }
            .map {
                ToolAwarenessEntry(
                    descriptor: $0,
                    environment: environment,
                    authorizedOperations: authorizedOperations
                )
            }
            .sorted {
                $0.namespace == $1.namespace
                    ? $0.name < $1.name
                    : $0.namespace < $1.namespace
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
        search(
            query: query,
            namespace: namespace,
            limit: limit,
            activeSkillID: activeSkillID,
            authorizedOperations: nil
        )
    }

    /// 按自然语言做轻量确定性加权检索。
    ///
    /// 兼容原调用（整句 substring 过滤 + 简单评分）。
    /// `authorizedOperations` 仅为旧调用方保留，不会把普通 mutation 隐藏
    /// 或标记为不可执行；破坏性工具仍由 descriptor 的确认策略处理。
    ///
    /// 检索不要求 query 完整出现在 summary：tokenize 后 OR 匹配，
    /// “把歌曲安排成下一首播放”也能命中 `queue_play_next`。
    public func search(
        query: String,
        namespace: String? = nil,
        limit: Int = 8,
        activeSkillID: String? = nil,
        authorizedOperations: Set<ToolAuthorizationOperation>?
    ) -> [ToolCatalogEntry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let namespaceNeedle = namespace?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let tokens = Self.tokens(from: needle)
        let filtered = descriptors.filter { descriptor in
            guard descriptor.isVisible(toSkillID: activeSkillID) else { return false }
            guard namespaceNeedle.map({ descriptor.namespace.lowercased() == $0 }) ?? true else { return false }
            guard !needle.isEmpty else { return true }
            return Self.matchesAnyToken(descriptor, tokens: tokens, needle: needle)
        }
        return filtered
            .sorted { lhs, rhs in
                score(lhs, needle: needle, tokens: tokens) > score(rhs, needle: needle, tokens: tokens)
            }
            .prefix(min(max(limit, 1), 50))
            .map { descriptor in
                _ = authorizedOperations
                return ToolCatalogEntry(descriptor: descriptor, authorized: nil)
            }
    }

    /// 中文短语 + ASCII tokenization。中文按连续 CJK 段切分，再对 3+ 字符
    /// 段落生成 2-gram，保证“下一首播放”能与“queue_play_next”的标签/摘要匹配。
    static func tokens(from needle: String) -> [String] {
        let trimmed = needle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return [] }
        var result: [String] = []
        // ASCII word tokens.
        let ascii = trimmed.split { $0.isASCII && !$0.isLetter && !$0.isNumber }
            .filter { !$0.isEmpty }
            .map(String.init)
        result.append(contentsOf: ascii)
        // CJK contiguous segments + 2-grams for segments >= 3.
        let cjk = trimmed.split { character in
            character.isASCII || !character.isLetter
        }.filter { !$0.isEmpty }
        for segment in cjk {
            let text = String(segment)
            if text.count >= 3 {
                let grams = (0...(text.count - 2)).map { start in
                    String(text.dropFirst(start).prefix(2))
                }
                result.append(contentsOf: grams)
            } else {
                result.append(text)
            }
        }
        return Array(Set(result)).filter { !$0.isEmpty }
    }

    private static func matchesAnyToken(
        _ descriptor: ToolDescriptor,
        tokens: [String],
        needle: String
    ) -> Bool {
        let name = descriptor.name.lowercased()
        let namespace = descriptor.namespace.lowercased()
        let aliases = descriptor.aliases.map { $0.lowercased() }
        let tags = descriptor.tags.map { $0.lowercased() }
        let summary = descriptor.summary.lowercased()
        let operation = descriptor.authorizationOperation?.rawValue.lowercased()
        if name.contains(needle)
            || namespace.contains(needle)
            || aliases.contains(where: { $0.contains(needle) })
            || tags.contains(where: { $0.contains(needle) })
            || summary.contains(needle)
            || (operation.map { $0.contains(needle) } ?? false) {
            return true
        }
        for token in tokens where token.count >= 2 {
            if name.contains(token)
                || namespace.contains(token)
                || aliases.contains(where: { $0.contains(token) })
                || tags.contains(where: { $0.contains(token) })
                || summary.contains(token)
                || (operation.map { $0.contains(token) } ?? false) {
                return true
            }
        }
        return false
    }

    private func score(_ descriptor: ToolDescriptor, needle: String, tokens: [String]) -> Int {
        guard !needle.isEmpty else { return 0 }
        let name = descriptor.name.lowercased()
        let namespace = descriptor.namespace.lowercased()
        let aliases = descriptor.aliases.map { $0.lowercased() }
        let tags = descriptor.tags.map { $0.lowercased() }
        let summary = descriptor.summary.lowercased()
        let operation = descriptor.authorizationOperation?.rawValue.lowercased()
        var result = 0
        if name == needle { result += 1_000 }
        if aliases.contains(needle) { result += 900 }
        if operation == needle { result += 900 }
        if namespace == needle { result += 300 }
        if tags.contains(needle) { result += 250 }
        if name.contains(needle) { result += 150 }
        if aliases.contains(where: { $0.contains(needle) }) { result += 120 }
        if summary.contains(needle) { result += 40 }
        for token in tokens where token.count >= 2 {
            if name.contains(token) { result += 100 }
            if operation.map({ $0.contains(token) }) ?? false { result += 90 }
            if namespace.contains(token) { result += 60 }
            if tags.contains(where: { $0.contains(token) }) { result += 60 }
            if summary.contains(token) { result += 40 }
            if aliases.contains(where: { $0.contains(token) }) { result += 40 }
        }
        // 自然语言示例参与 ranking：完整示例子串命中权重高；token 命中次之。
        let examples = descriptor.utteranceExamples.map { $0.lowercased() }
        if examples.contains(needle) { result += 800 }
        for example in examples {
            if example.contains(needle) {
                result += 350
                break
            }
            if tokens.contains(where: { $0.count >= 2 && example.contains($0) }) {
                result += 80
            }
        }
        // Coverage 加权：命中 meaningful token 数 / 总 token 数越高排名越高，
        // 例如「下一首播放」同时命中 play_next 相关概念的工具应高于只命中一个的工具。
        let meaningful = tokens.filter { $0.count >= 2 }
        if !meaningful.isEmpty {
            var hitCount = 0
            for token in meaningful {
                if name.contains(token) || namespace.contains(token)
                    || tags.contains(where: { $0.contains(token) })
                    || summary.contains(token) || operation.map({ $0.contains(token) }) ?? false
                    || examples.contains(where: { $0.contains(token) }) {
                    hitCount += 1
                }
            }
            result += Int((Double(hitCount) / Double(meaningful.count)) * 200)
        }
        return result
    }
}
