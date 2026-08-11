import Foundation

/// 版本信息的唯一事实来源：一律从 Bundle 读取
/// （CFBundleShortVersionString / CFBundleVersion），不再硬编码版本号。
/// 显示格式：`1.0.2 (3)`。
enum AppVersionInfo {
    /// 用户可读版本，如 `1.0.2 (3)`。
    static var display: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "1.0.2"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            ?? ""
        return build.isEmpty ? short : "\(short) (\(build))"
    }

    /// 纯版本号（不含构建号），用于日志与诊断。
    static var short: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "1.0.2"
    }
}
