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

    // MARK: - Signal / Exception 专用静态状态（nonisolated，供非 MainActor 上下文使用）

    /// 崩溃日志文件路径（exception handler 是非 MainActor 的 C 闭包，无法访问实例）。
    private nonisolated(unsafe) static var crashLogPath: String?
    /// 预打开的崩溃日志 fd：signal handler 内只能使用 POSIX write() 追加。
    /// signal handler 运行在任意线程、任意 Swift runtime 状态下，绝不能触碰
    /// Task / MainActor / Foundation 文件 API / JSONEncoder / 字符串拼接。
    fileprivate nonisolated(unsafe) static var crashSignalFD: Int32 = -1

    private init() {
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
        logDirectory = caches.appendingPathComponent("CrashLogs", isDirectory: true)
        crashLogFile = logDirectory.appendingPathComponent("last_crash.log")
        try? fileManager.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        Self.crashLogPath = crashLogFile.path
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
    /// 只清内存缓冲 + truncate 同一 inode，绝不 unlink 文件——
    /// signal handler 预打开的 fd（O_APPEND）仍指向该 inode，unlink 后
    /// 写入会落到一个用户再也找不到的孤儿 inode，导致「普通日志在新文件、
    /// signal 记录在旧文件」的分裂。
    /// truncate 与 log() 的磁盘写入共用同一串行 logQueue（R10）：队列中已排队的
    /// 写入先落盘、随后 truncate，保证 ordering，不会出现「清除后又看到清除前的日志」。
    /// truncate 用同步执行（而非 async）：clear 是低频用户操作，必须保证返回时
    /// 磁盘文件已清空，否则 recent() 在 ringBuffer 为空时会立即回退读到刚清掉前的旧内容。
    public func clearCrashLog() {
        ringBuffer.removeAll()
        let fileURL = crashLogFile
        Self.logQueue.sync {
            guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
            do {
                try handle.truncate(atOffset: 0)
                try handle.close()
            } catch {
                try? handle.close()
            }
        }
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

    // MARK: - 线程安全同步追加（非 MainActor 路径）

    /// 同步、线程安全地向崩溃日志文件追加一行。
    /// 专供 NSSetUncaughtExceptionHandler 等非 MainActor 上下文使用；
    /// 不依赖 Task / MainActor / 串行队列，调用方负责传已脱敏文本。
    private nonisolated static func appendRawSync(_ text: String, to path: String) {
        guard !text.isEmpty else { return }
        let url = URL(fileURLWithPath: path)
        let data = Data(text.utf8)
        let fm = FileManager.default
        if fm.fileExists(atPath: path) {
            if let fh = try? FileHandle(forWritingTo: url) {
                fh.seekToEndOfFile()
                fh.write(data)
                try? fh.close()
            }
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: - Handler 安装

    /// 安装信号和异常处理器，在崩溃时记录现场。
    ///
    /// 设计约束：
    /// - Objective-C uncaught exception 运行在 ObjC 异常机制内（非异步信号上下文），
    ///   允许保留较丰富信息，但绝不使用 Task / MainActor——写盘走同步 appendRawSync。
    /// - POSIX signal（SIGSEGV / SIGBUS / SIGABRT 等）可能打断任意线程的任意代码，
    ///   handler 内只允许 POSIX write() + 预定义字面量，见 writeSignalRecord(_:)。
    public func installHandlers() {
        Self.crashLogPath = crashLogFile.path

        // 幂等（R10）：重复调用先关闭已打开的 fd，避免 fd 泄漏。
        if Self.crashSignalFD >= 0 {
            close(Self.crashSignalFD)
            Self.crashSignalFD = -1
        }

        // 预打开崩溃日志 fd：signal handler 内只追加，不打开/关闭文件。
        // O_CLOEXEC 防止 exec 后 fd 泄漏；O_APPEND 保证每次 write 原子追加到文件尾。
        let fd = open(crashLogFile.path, O_CREAT | O_WRONLY | O_APPEND | O_CLOEXEC, 0o644)
        if fd >= 0 {
            Self.crashSignalFD = fd
        }

        // 捕获 Swift 致命错误 / Objective-C 异常
        NSSetUncaughtExceptionHandler { exception in
            let reason = """
            [未捕获异常]
            名称: \(exception.name.rawValue)
            原因: \(exception.reason ?? "未知")
            调用栈:
            \(exception.callStackSymbols.joined(separator: "\n"))
            """
            guard let path = CrashLog.crashLogPath else { return }
            CrashLog.appendRawSync(CrashLog.sanitize(reason) + "\n", to: path)
        }

        // 捕获 Unix 信号（SIGABRT, SIGSEGV, SIGBUS, SIGTRAP, SIGILL 等）。
        // handler 是 @convention(c) 闭包：不捕获上下文，不触碰 Swift runtime。
        let signals: [Int32] = [SIGABRT, SIGSEGV, SIGBUS, SIGTRAP, SIGILL, SIGFPE, SIGPIPE]
        for sig in signals {
            signal(sig) { s in
                writeSignalRecord(s)
                // 恢复默认处理并重新发送信号，让系统完成崩溃流程（产生系统 crash report）。
                signal(s, SIG_DFL)
                raise(s)
            }
        }
    }
}

/// 极简 signal-safe 记录：只用 POSIX write() + strlen() + 静态字面量，
/// 不构造 String、不分配内存、不触碰任何 Swift runtime / Foundation / 并发原语。
/// fd 在 installHandlers() 中预打开（O_APPEND），此处只追加。
@inline(__always)
private func writeSignalRecord(_ signalNumber: Int32) {
    let fd = CrashLog.crashSignalFD
    guard fd >= 0 else { return }
    // StaticString 是编译期只读段字面量：不构造 String、不分配堆内存、
    // 不触碰 Swift runtime，满足 signal handler 的 async-signal-safe 要求。
    let literal: StaticString
    switch signalNumber {
    case SIGABRT: literal = "[signal] SIGABRT\n"
    case SIGSEGV: literal = "[signal] SIGSEGV\n"
    case SIGBUS:  literal = "[signal] SIGBUS\n"
    case SIGTRAP: literal = "[signal] SIGTRAP\n"
    case SIGILL:  literal = "[signal] SIGILL\n"
    case SIGFPE:  literal = "[signal] SIGFPE\n"
    case SIGPIPE: literal = "[signal] SIGPIPE\n"
    default:      literal = "[signal] UNKNOWN\n"
    }
    _ = write(fd, literal.utf8Start, literal.utf8CodeUnitCount)
}
