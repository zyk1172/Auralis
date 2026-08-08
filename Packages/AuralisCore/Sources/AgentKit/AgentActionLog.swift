import Foundation

/// 修改型操作的本地日志，支持查看与尽可能撤销。
public actor AgentActionLog {
    private let fileURL: URL
    private var records: [AgentActionRecord]

    public init(fileURL: URL) {
        self.fileURL = fileURL
        self.records = Self.load(from: fileURL) ?? []
    }

    public var all: [AgentActionRecord] {
        records.sorted { $0.timestamp > $1.timestamp }
    }

    public func add(_ record: AgentActionRecord) {
        records.append(record)
        try? persist()
    }

    public func markUndone(_ id: UUID) {
        if let index = records.firstIndex(where: { $0.id == id }) {
            records[index].undone = true
            try? persist()
        }
    }

    public func clear() {
        records.removeAll()
        try? persist()
    }

    private func persist() throws {
        let data = try JSONEncoder().encode(records)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL)
    }

    private static func load(from url: URL) -> [AgentActionRecord]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([AgentActionRecord].self, from: data)
    }
}
