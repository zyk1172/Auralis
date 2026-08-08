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
        self.serverID = serverID
        self.summary = summary
        self.structuredFilters = structuredFilters
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
        }
    }
}

/// 会话持久化与查询。
public actor SessionStore {
    private let fileURL: URL
    private var cache: [UUID: AgentSession] = [:]

    public init(fileURL: URL) {
        self.fileURL = fileURL
        self.cache = Self.load(from: fileURL) ?? [:]
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
        try? persist()
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
        try? persist()
    }

    public func rename(_ id: UUID, to title: String) {
        guard var session = cache[id] else { return }
        session.title = title
        session.updatedAt = .now
        cache[id] = session
        try? persist()
    }

    public func setPinned(_ id: UUID, _ pinned: Bool) {
        guard var session = cache[id] else { return }
        session.isPinned = pinned
        session.updatedAt = .now
        cache[id] = session
        try? persist()
    }

    public func setSummary(_ id: UUID, _ summary: String) {
        guard var session = cache[id] else { return }
        session.summary = summary
        cache[id] = session
        try? persist()
    }

    public func clearMessages(_ id: UUID) {
        guard var session = cache[id] else { return }
        session.messages.removeAll()
        session.updatedAt = .now
        cache[id] = session
        try? persist()
    }

    public func delete(_ id: UUID) {
        cache.removeValue(forKey: id)
        try? persist()
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

    private func persist() throws {
        let list = Array(cache.values)
        let data = try JSONEncoder().encode(list)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL)
    }

    private static func load(from url: URL) -> [UUID: AgentSession]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let list = try? JSONDecoder().decode([AgentSession].self, from: data)
        return list.map { Dictionary(uniqueKeysWithValues: $0.map { ($0.id, $0) }) }
    }

    private static func deriveTitle(from message: AgentChatMessage) -> String {
        if case let .text(value) = message.messages.first {
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            return String(trimmed.prefix(24))
        }
        return "新会话"
    }
}
