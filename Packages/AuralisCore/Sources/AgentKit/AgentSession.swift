import Domain
import Foundation
import LocalCatalog

/// 一次 Agent 会话。
public struct AgentSession: Codable, Sendable, Identifiable {
    public let id: UUID
    public var title: String
    public var messages: [AgentChatMessage]
    public var createdAt: Date
    public var updatedAt: Date
    public var isPinned: Bool
    public var isArchived: Bool
    public var serverID: ServerID?
    public var summary: String?
    public var structuredFilters: [String: String]

    public init(
        id: UUID = UUID(),
        title: String = "新会话",
        messages: [AgentChatMessage] = [],
        createdAt: Date = .now,
        updatedAt: Date = .now,
        isPinned: Bool = false,
        isArchived: Bool = false,
        serverID: ServerID? = nil,
        summary: String? = nil,
        structuredFilters: [String: String] = [:]
    ) {
        self.id = id
        self.title = title
        self.messages = messages
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isPinned = isPinned
        self.isArchived = isArchived
        self.serverID = serverID
        self.summary = summary
        self.structuredFilters = structuredFilters
    }

    /// 向后兼容解码：旧持久化数据没有 `isArchived` 键，缺省按未归档处理。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        messages = try c.decodeIfPresent([AgentChatMessage].self, forKey: .messages) ?? []
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .now
        isPinned = try c.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        isArchived = try c.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
        serverID = try c.decodeIfPresent(ServerID.self, forKey: .serverID)
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        structuredFilters = try c.decodeIfPresent([String: String].self, forKey: .structuredFilters) ?? [:]
    }

    public var tokenEstimate: Int {
        messages.reduce(0) { total, message in
            total + message.messages.reduce(0) { $0 + estimateTokens($1) }
        }
    }

    private func estimateTokens(_ message: AgentMessage) -> Int {
        switch message {
        case let .text(value): return value.count / 2
        case let .trackCards(cards): return cards.count * 12
        case let .albumCards(cards): return cards.count * 8
        case let .playlistProposal(name, tracks): return name.count / 2 + tracks.count * 12
        case let .actionPreview(title, _): return title.count / 2
        case let .toolProgress(step): return step.count / 2
        case let .error(value): return value.count / 2
        case .confirmation: return 8
        case let .streaming(value): return value.count / 2
        }
    }
}

/// 会话持久化与查询。
public actor SessionStore {
    private let fileURL: URL
    /// 轮换备份：主文件损坏时回退（避免 decode 失败表现为“所有会话消失”）。
    private let backupURL: URL
    private var cache: [UUID: AgentSession] = [:]

    public init(fileURL: URL) {
        self.fileURL = fileURL
        let dir = fileURL.deletingLastPathComponent()
        let base = fileURL.deletingPathExtension().lastPathComponent
        let ext = fileURL.pathExtension
        self.backupURL = dir.appendingPathComponent("\(base).backup.\(ext)")
        self.cache = Self.load(from: fileURL, fallback: backupURL) ?? [:]
    }

    public var all: [AgentSession] {
        cache.values.sorted {
            if $0.isPinned != $1.isPinned { return $0.isPinned }
            return $0.updatedAt > $1.updatedAt
        }
    }

    public func session(_ id: UUID) -> AgentSession? { cache[id] }

    public func create(serverID: ServerID? = nil) -> AgentSession {
        let session = AgentSession(serverID: serverID)
        cache[session.id] = session
        persistSafely(operation: "create")
        return session
    }

    public func append(_ message: AgentChatMessage, to id: UUID) {
        guard var session = cache[id] else { return }
        session.messages.append(message)
        session.updatedAt = .now
        if session.title == "新会话", let firstUser = session.messages.first(where: { $0.role == .user }) {
            session.title = Self.deriveTitle(from: firstUser)
        }
        cache[id] = session
        persistSafely(operation: "append")
    }

    public func rename(_ id: UUID, to title: String) {
        guard var session = cache[id] else { return }
        session.title = title
        session.updatedAt = .now
        cache[id] = session
        persistSafely(operation: "rename")
    }

    public func setPinned(_ id: UUID, _ pinned: Bool) {
        guard var session = cache[id] else { return }
        session.isPinned = pinned
        session.updatedAt = .now
        cache[id] = session
        persistSafely(operation: "setPinned")
    }

    public func setArchived(_ id: UUID, _ archived: Bool) {
        guard var session = cache[id] else { return }
        session.isArchived = archived
        session.updatedAt = .now
        cache[id] = session
        persistSafely(operation: "setArchived")
    }

    public func setSummary(_ id: UUID, _ summary: String) {
        guard var session = cache[id] else { return }
        session.summary = summary
        cache[id] = session
        persistSafely(operation: "setSummary")
    }

    public func clearMessages(_ id: UUID) {
        guard var session = cache[id] else { return }
        session.messages.removeAll()
        session.updatedAt = .now
        cache[id] = session
        persistSafely(operation: "clearMessages")
    }

    public func delete(_ id: UUID) {
        cache.removeValue(forKey: id)
        persistSafely(operation: "delete")
    }

    public func search(_ query: String) -> [AgentSession] {
        let q = query.lowercased()
        return all.filter { session in
            session.title.lowercased().contains(q) ||
            session.messages.contains { message in
                message.messages.contains {
                    if case let .text(value) = $0 { return value.lowercased().contains(q) }
                    return false
                }
            }
        }
    }

    public func sessions(forServer serverID: ServerID) -> [AgentSession] {
        all.filter { $0.serverID == serverID }
    }

    // MARK: - Persistence

    /// 原子持久化：主文件 + 轮换备份。
    /// - 主文件用 `.atomic`（临时文件 + rename），进程中途被杀也不会留下截断 JSON；
    /// - 主文件成功后把同一份数据写入备份文件（同样原子），load 时主文件损坏可回退备份。
    private func persist() throws {
        let list = Array(cache.values)
        let data = try JSONEncoder().encode(list)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
        try data.write(to: backupURL, options: .atomic)
    }

    /// 持久化失败不静默：DEBUG 下断言暴露问题；Release 下保持不崩溃（actor 内下次写入会重试）。
    /// AgentKit 不依赖 Observability，避免为日志反向破坏包依赖方向。
    private func persistSafely(operation: StaticString) {
        do {
            try persist()
        } catch {
            #if DEBUG
            assertionFailure("AgentSession 持久化失败（\(operation)）: \(error)")
            #else
            _ = operation
            #endif
        }
    }

    /// 主文件优先，decode 失败回退备份；两者都失败才返回 nil（保持内存态为空）。
    private static func load(from url: URL, fallback backupURL: URL) -> [UUID: AgentSession]? {
        if let sessions = decode(from: url) { return sessions }
        if let sessions = decode(from: backupURL) { return sessions }
        return nil
    }

    private static func decode(from url: URL) -> [UUID: AgentSession]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let list = try? JSONDecoder().decode([AgentSession].self, from: data) else { return nil }
        // 用 uniquingKeysWith 兜底重复 id，避免 Dictionary(uniqueKeysWithValues:) 直接 fatalError
        return Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private static func deriveTitle(from message: AgentChatMessage) -> String {
        if case let .text(value) = message.messages.first {
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            return String(trimmed.prefix(24))
        }
        return "新会话"
    }
}
