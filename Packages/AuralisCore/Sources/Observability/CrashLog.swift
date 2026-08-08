import Foundation

/// 崩溃日志管理器：捕获未处理的异常和信号，写入文件供下次启动时查看。
/// 使用 @MainActor 确保线程安全。
@MainActor
public final class CrashLog {
    public static let shared = CrashLog()

    private let logDirectory: URL
    private let crashLogFile: URL
    private let fileManager = FileManager.default
    /// 磁盘写入统一走后台串行队列，避免主线程同步 I/O（播放路径高频调用会卡 UI）。
    private nonisolated static let logQueue = DispatchQueue(label: "auralis.crashlog.write", qos: .utility)
    /// 复用的时间戳格式器（DateFormatter 创建开销大，避免每次调用新建）。
    private nonisolated static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        f.locale = Locale(identifier: "zh_CN")
        return f
    }()
    /// 内存环形缓冲：最近 200 条，供 recent() 即时读取，不受磁盘异步写入影响。
    private var ringBuffer: [String] = []
    private let ringLimit = 200

    private init() {
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
        logDirectory = caches.appendingPathComponent("CrashLogs", isDirectory: true)
        crashLogFile = logDirectory.appendingPathComponent("last_crash.log")
        try? fileManager.createDirectory(at: logDirectory, withIntermediateDirectories: true)
    }

    // MARK: - Public API

    /// 读取上次崩溃日志（如果有）。
    public func readLastCrashLog() -> String? {
        guard fileManager.fileExists(atPath: crashLogFile.path),
              let data = try? Data(contentsOf: crashLogFile),
              let text = String(data: data, encoding: .utf8),
              !text.isEmpty else {
            return nil
        }
        return text
    }

    /// 清除崩溃日志（用户查看后调用）。
    public func clearCrashLog() {
        try? fileManager.removeItem(at: crashLogFile)
    }

    /// 写入一条带时间戳的日志条目（用于关键操作追踪）。
    /// 写入前统一脱敏：绝不落盘密码、Token、API Key 或带认证参数的完整 URL。
    /// 主线程只做内存缓冲追加（O(1)）；磁盘写后台异步执行，不阻塞 UI。
    public func log(_ message: String) {
        let timestamp = Self.formatter.string(from: Date())
        let entry = "[\(timestamp)] \(Self.sanitize(message))\n"
        ringBuffer.append(entry)
        if ringBuffer.count > ringLimit {
            ringBuffer.removeFirst(ringBuffer.count - ringLimit)
        }
        guard let data = entry.data(using: .utf8) else { return }
        let fileURL = crashLogFile
        Self.logQueue.async {
            let fm = FileManager.default
            if fm.fileExists(atPath: fileURL.path) {
                if let fh = try? FileHandle(forWritingTo: fileURL) {
                    fh.seekToEndOfFile()
                    fh.write(data)
                    try? fh.close()
                }
            } else {
                try? data.write(to: fileURL, options: .atomic)
            }
        }
    }

    /// 读取最近 N 条日志（脱敏：仅时间戳 + 文本行，不含凭据 / 完整路径 / 认证 URL）。
    /// 优先返回内存缓冲（即时、无磁盘 I/O）；空时才回退读文件。
    public func recent(limit: Int) -> [(timestamp: Date, category: String, summary: String)] {
        let lines: [String]
        if ringBuffer.isEmpty {
            guard let text = readLastCrashLog() else { return [] }
            lines = text.split(separator: "\n").map(String.init)
        } else {
            lines = ringBuffer
        }
        return lines.suffix(max(limit, 1)).map { (timestamp: Date.now, category: "log", summary: Self.sanitize($0)) }
    }

    /// 防御性脱敏：把认证参数值（密码 / token / salt / apikey 等）与 Authorization 头替换为 <redacted>。
    /// 在写入时与读取时各执行一次，双保险：即使调用方忘记脱敏，也不会泄露给模型或日志文件。
    public nonisolated static func sanitize(_ message: String) -> String {
        var result = message
        // 先脱敏 URL userinfo（scheme://user:pass@host → scheme://<redacted>@host），
        // 再处理查询参数与认证头：防御两层，保证密码/Token/API Key 不进日志文件。
        let userinfo = #"(://)([^/@:\s]+)(:[^/@\s]*)?@"#
        result = result.replacingOccurrences(of: userinfo, with: "$1<redacted>@", options: .regularExpression)
        let authQuery = #"(?i)([?&])(u|p|t|s|apikey|api_key|token|access_token|password|passwd|credential|key|signature)=([^&\s"']*)"#
        result = result.replacingOccurrences(of: authQuery, with: "$1$2=<redacted>", options: .regularExpression)
        let authHeader = #"(?i)(authorization|proxy-authorization|cookie|x-api-key|api-key):[ \t]*(?:bearer[ \t]+)?[^\s]+"#
        result = result.replacingOccurrences(of: authHeader, with: "$1: <redacted>", options: .regularExpression)
        return result
    }

    /// 安装信号和异常处理器，在崩溃时记录现场。
    public func installHandlers() {
        // 捕获 Swift致命错误（fatalError / assert / precondition 失败）
        // 利用 NSSetUncaughtExceptionHandler 捕获 Objective-C 异常
        NSSetUncaughtExceptionHandler { exception in
            let reason = """
            [未捕获异常]
            名称: \(exception.name.rawValue)
            原因: \(exception.reason ?? "未知")
            调用栈:
            \(exception.callStackSymbols.joined(separator: "\n"))
            """
            Task { @MainActor in
                CrashLog.shared.log(reason)
            }
        }

        // 捕获 Unix 信号（SIGABRT, SIGSEGV, SIGBUS, SIGTRAP, SIGILL 等）
        let signals: [Int32] = [SIGABRT, SIGSEGV, SIGBUS, SIGTRAP, SIGILL, SIGFPE, SIGPIPE]
        for sig in signals {
            signal(sig) { s in
                let name: String
                switch s {
                case SIGABRT: name = "SIGABRT"
                case SIGSEGV: name = "SIGSEGV"
                case SIGBUS:  name = "SIGBUS"
                case SIGTRAP: name = "SIGTRAP"
                case SIGILL:  name = "SIGILL"
                case SIGFPE:  name = "SIGFPE"
                case SIGPIPE: name = "SIGPIPE"
                default:      name = "SIGNAL(\(s))"
                }
                let reason = "[信号崩溃] \(name) (signal \(s))"
                Task { @MainActor in
                    CrashLog.shared.log(reason)
                }
                // 恢复默认处理并重新发送信号，让系统完成崩溃流程
                signal(s, SIG_DFL)
                raise(s)
            }
        }
    }
}
