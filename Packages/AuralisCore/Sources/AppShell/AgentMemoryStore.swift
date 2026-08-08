import AgentKit
import Foundation

/// 跨会话记忆与简单 skill 的本地存储（App Shell）。
///
/// - 记忆：`<App Support>/Auralis/agent-memory.json`，结构化 `[AgentMemoryEntry]`。
/// - 技能：`<App Support>/Auralis/skills/<名字>.md`，一段指令一个文件（skill 文件）。
///
/// 与 `AgentCoordinator` / `AuralisSystemToolService` 共享同一实例，
/// 保证会话内注入的记忆与工具写入的记忆缓存一致；文件落盘保证下次会话仍在。
@MainActor
public final class AgentMemoryStore {
    private let directory: URL
    private let memoryFile: URL
    private let skillsDirectory: URL
    private var entries: [AgentMemoryEntry] = []

    public static let maxValueLength = 2_000
    public static let maxInstructionsLength = 20_000
    public static let maxMemoryCount = 200

    public init(directory: URL? = nil) {
        let dir = directory ?? Self.defaultDirectory()
        self.directory = dir
        self.memoryFile = dir.appendingPathComponent("agent-memory.json")
        self.skillsDirectory = dir.appendingPathComponent("skills", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: skillsDirectory, withIntermediateDirectories: true)
        self.entries = Self.loadMemory(from: memoryFile)
    }

    /// 与 AgentCoordinator 相同的默认目录（App Support/Auralis）。
    public static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Auralis", isDirectory: true)
    }

    // MARK: - 记忆

    /// 当前全部记忆（按最近更新倒序）。
    public var memories: [AgentMemoryEntry] {
        entries.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// 保存 / 覆盖一条记忆（upsert）。key 不能为空或含换行；value 不能为空且限长。
    @discardableResult
    public func saveMemory(key: String, value: String) -> Bool {
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty, !trimmedValue.isEmpty,
              !trimmedKey.contains(where: \.isNewline),
              trimmedKey.count <= 200,
              trimmedValue.count <= Self.maxValueLength else {
            return false
        }
        let entry = AgentMemoryEntry(key: trimmedKey, value: trimmedValue, updatedAt: .now)
        if let index = entries.firstIndex(where: { $0.key == trimmedKey }) {
            entries[index] = entry
        } else {
            entries.append(entry)
            if entries.count > Self.maxMemoryCount {
                entries.sort { $0.updatedAt > $1.updatedAt }
                entries = Array(entries.prefix(Self.maxMemoryCount))
            }
        }
        return persistMemory()
    }

    /// 删除一条记忆；不存在返回 false。
    @discardableResult
    public func deleteMemory(key: String) -> Bool {
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let before = entries.count
        entries.removeAll { $0.key == trimmedKey }
        guard entries.count != before else { return false }
        return persistMemory()
    }

    /// 清空全部记忆；返回删除条数。
    public func clearMemory() -> Int {
        let count = entries.count
        guard count > 0 else { return 0 }
        entries.removeAll()
        persistMemory()
        return count
    }

    // MARK: - 技能

    /// 当前全部技能（按名称排序）。每个技能对应一个 `skills/<名字>.md` 文件。
    public var skills: [AgentSkillEntry] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: skillsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return urls.compactMap { url -> AgentSkillEntry? in
            guard url.pathExtension.lowercased() == "md" else { return nil }
            let name = url.deletingPathExtension().lastPathComponent
            guard let data = try? Data(contentsOf: url),
                  let instructions = String(data: data, encoding: .utf8) else { return nil }
            let created = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .now
            return AgentSkillEntry(name: name, instructions: instructions, createdAt: created)
        }.sorted { $0.name < $1.name }
    }

    /// 创建技能（写 `skills/<名字>.md`）。返回落盘后的技能（名字为规范化后的文件名）。
    @discardableResult
    public func createSkill(name: String, instructions: String) -> AgentSkillEntry? {
        let trimmedName = Self.sanitizedSkillName(name)
        let trimmedInstructions = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty,
              !trimmedInstructions.isEmpty,
              trimmedInstructions.count <= Self.maxInstructionsLength else { return nil }
        let url = skillsDirectory.appendingPathComponent(trimmedName + ".md")
        guard let data = trimmedInstructions.data(using: .utf8) else { return nil }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            return nil
        }
        let created = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .now
        return AgentSkillEntry(name: trimmedName, instructions: trimmedInstructions, createdAt: created)
    }

    /// 读取某个技能的完整指令；不存在返回 nil。
    public func readSkill(name: String) -> AgentSkillEntry? {
        let trimmedName = Self.sanitizedSkillName(name)
        guard !trimmedName.isEmpty else { return nil }
        let url = skillsDirectory.appendingPathComponent(trimmedName + ".md")
        guard let data = try? Data(contentsOf: url),
              let instructions = String(data: data, encoding: .utf8) else { return nil }
        let created = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .now
        return AgentSkillEntry(name: trimmedName, instructions: instructions, createdAt: created)
    }

    /// 删除一个技能；不存在返回 false。
    @discardableResult
    public func deleteSkill(name: String) -> Bool {
        let trimmedName = Self.sanitizedSkillName(name)
        guard !trimmedName.isEmpty else { return false }
        let url = skillsDirectory.appendingPathComponent(trimmedName + ".md")
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        do {
            try FileManager.default.removeItem(at: url)
            return true
        } catch {
            return false
        }
    }

    // MARK: - 内部

    /// 技能名 → 安全文件名：去掉路径分隔符、控制字符与非法字符，折叠连续横线。
    /// 中文等常规字符原样保留；结果为空时回退为 `skill`。
    static func sanitizedSkillName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        var scalars: [Unicode.Scalar] = []
        for scalar in trimmed.unicodeScalars {
            switch scalar {
            case "/", "\\", ":", "?", "%", "*", "\"", "|", "<", ">", "\n", "\r", "\t", "\0":
                scalars.append(Unicode.Scalar(0x2D)!)
            case let s where s.value < 32:
                continue
            default:
                scalars.append(scalar)
            }
        }
        var result = String(String.UnicodeScalarView(scalars))
        while result.contains("--") {
            result = result.replacingOccurrences(of: "--", with: "-")
        }
        result = result.trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        if result == "." || result == ".." { result = "" }
        return result.isEmpty ? "skill" : result
    }

    @discardableResult
    private func persistMemory() -> Bool {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(entries)
            try data.write(to: memoryFile, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    private static func loadMemory(from fileURL: URL) -> [AgentMemoryEntry] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([AgentMemoryEntry].self, from: data)) ?? []
    }
}
