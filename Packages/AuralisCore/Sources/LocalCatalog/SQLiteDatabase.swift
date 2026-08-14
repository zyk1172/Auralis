import Foundation
import Observability
import SQLite3

/// SQLite 绑值类型。
public enum SQLiteValue: Sendable, Equatable {
    case text(String)
    case integer(Int64)
    case real(Double)
    case null

    var string: String? {
        if case let .text(value) = self { return value }
        return nil
    }
    var int: Int64? {
        if case let .integer(value) = self { return value }
        return nil
    }
    var double: Double? {
        switch self {
        case let .real(value): return value
        case let .integer(value): return Double(value)
        default: return nil
        }
    }
}

/// 极简 SQLite3 封装：打开、执行、参数绑定、行查询。
/// 仅用于本地目录，所有访问经 LocalCatalogStore actor 串行化。
final class SQLiteDatabase: @unchecked Sendable {
    private var handle: OpaquePointer?

    init(url: URL) throws {
        if url.path != ":memory:" {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        }
        var openedHandle: OpaquePointer?
        try StartupPerformanceTrace.measure(.sqliteOpen) {
            guard sqlite3_open(url.path, &openedHandle) == SQLITE_OK, openedHandle != nil else {
                throw LocalCatalogError.openFailed(url.path)
            }
        }
        guard let openedHandle else { throw LocalCatalogError.openFailed(url.path) }
        self.handle = openedHandle
        try exec("PRAGMA journal_mode = WAL;")
        try exec("PRAGMA foreign_keys = ON;")
        // App 与 Siri/小组件扩展共享同一 App Group 数据库：设置 busy_timeout，
        // 避免并发写直接返回 SQLITE_BUSY 而失败。
        try exec("PRAGMA busy_timeout = 5000;")
    }

    /// 显式完整性检查。调用方负责在本地目录已可用后按时间策略后台执行，避免每次
    /// 打开数据库都同步扫描并阻塞冷启动。
    func quickCheck() throws {
        let statement = try prepare("PRAGMA quick_check;")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let text = sqlite3_column_text(statement, 0)
        else {
            throw LocalCatalogError.openFailed("integrity check unavailable")
        }
        let result = String(cString: text)
        guard result.lowercased() == "ok" else {
            throw LocalCatalogError.openFailed("integrity check failed: \(result.prefix(120))")
        }
    }

    deinit {
        sqlite3_close(handle)
    }

    func exec(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(error)
            throw LocalCatalogError.executeFailed("\(message) · SQL: \(sql.prefix(120))")
        }
    }

    /// 执行带参数的写语句。
    func run(_ sql: String, _ bindings: [SQLiteValue] = []) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE || result == SQLITE_ROW else {
            throw LocalCatalogError.executeFailed("step failed (\(result)): \(sql.prefix(120))")
        }
    }

    /// 执行查询，返回行字典数组。
    func query(_ sql: String, _ bindings: [SQLiteValue] = []) throws -> [[String: SQLiteValue]] {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)
        var rows: [[String: SQLiteValue]] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else {
                throw LocalCatalogError.executeFailed("query failed (\(result)): \(sql.prefix(120))")
            }
            var row: [String: SQLiteValue] = [:]
            let columnCount = sqlite3_column_count(statement)
            for index in 0..<columnCount {
                let name = String(cString: sqlite3_column_name(statement, index))
                switch sqlite3_column_type(statement, index) {
                case SQLITE_INTEGER:
                    row[name] = .integer(sqlite3_column_int64(statement, index))
                case SQLITE_FLOAT:
                    row[name] = .real(sqlite3_column_double(statement, index))
                case SQLITE_NULL:
                    row[name] = .null
                default:
                    row[name] = sqlite3_column_text(statement, index)
                        .map { .text(String(cString: $0)) } ?? .null
                }
            }
            rows.append(row)
        }
        return rows
    }

    /// 在事务中执行多个写操作。
    func transaction(_ body: () throws -> Void) throws {
        try exec("BEGIN IMMEDIATE;")
        do {
            try body()
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw LocalCatalogError.prepareFailed(sql.prefix(120).description)
        }
        return statement
    }

    private func bind(_ bindings: [SQLiteValue], to statement: OpaquePointer) throws {
        for (index, value) in bindings.enumerated() {
            let position = Int32(index + 1)
            let result: Int32
            switch value {
            case let .text(string):
                result = sqlite3_bind_text(statement, position, string, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            case let .integer(number):
                result = sqlite3_bind_int64(statement, position, number)
            case let .real(number):
                result = sqlite3_bind_double(statement, position, number)
            case .null:
                result = sqlite3_bind_null(statement, position)
            }
            guard result == SQLITE_OK else {
                throw LocalCatalogError.executeFailed("bind failed at \(position)")
            }
        }
    }
}
