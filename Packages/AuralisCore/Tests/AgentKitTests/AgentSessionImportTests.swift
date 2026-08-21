import AgentKit
import Foundation
import Testing

struct AgentSessionImportTests {
    @Test("会话导入返回报告并按 ID 跳过重复项")
    func importReportMergesWithoutDeletingExistingSessions() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("auralis-session-import-\(UUID().uuidString)", isDirectory: true)
        let currentDirectory = root.appendingPathComponent("current", isDirectory: true)
        let legacyDirectory = root.appendingPathComponent("legacy", isDirectory: true)
        try FileManager.default.createDirectory(at: currentDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let target = SessionStore(fileURL: currentDirectory.appendingPathComponent("agent-sessions.json"))
        let existing = await target.create()
        let imported = AgentSession(title: "旧会话")
        let data = try JSONEncoder().encode([
            existing,
            imported,
        ])
        try data.write(to: legacyDirectory.appendingPathComponent("agent-sessions.json"))

        let report = try await target.importSessions(from: legacyDirectory)
        let sessions = await target.all

        #expect(report.totalCount == 2)
        #expect(report.importedCount == 1)
        #expect(report.skippedExistingCount == 1)
        #expect(report.usedBackup == false)
        #expect(sessions.count == 2)
        #expect(sessions.contains(where: { $0.id == imported.id }))
    }

    @Test("主文件损坏时明确使用备份文件")
    func importUsesBackupWhenPrimaryIsInvalid() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("auralis-session-import-backup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try Data("not-json".utf8).write(to: root.appendingPathComponent("agent-sessions.json"))
        let imported = AgentSession(title: "备份会话")
        try JSONEncoder().encode([imported]).write(to: root.appendingPathComponent("agent-sessions.backup.json"))

        let target = SessionStore(fileURL: root.appendingPathComponent("current.json"))
        let report = try await target.importSessions(from: root)

        #expect(report.usedBackup)
        #expect(report.importedCount == 1)
        #expect((await target.all).contains(where: { $0.id == imported.id }))
    }
}
