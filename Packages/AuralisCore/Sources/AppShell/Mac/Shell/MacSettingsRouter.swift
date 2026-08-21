#if os(macOS)
import SwiftUI

/// Mac 设置窗口分类（与 Settings 场景共享，支持深链）。
public enum MacSettingsCategory: String, CaseIterable, Identifiable {
    case general
    case server
    case libraryPlayback
    case ai
    case system
    case about

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .general: String(localized: "通用", bundle: .module)
        case .server: String(localized: "服务器", bundle: .module)
        case .libraryPlayback: String(localized: "资料库与播放", bundle: .module)
        case .ai: String(localized: "AI 与公开数据", bundle: .module)
        case .system: String(localized: "系统", bundle: .module)
        case .about: String(localized: "关于", bundle: .module)
        }
    }

    public var symbol: String {
        switch self {
        case .general: "gearshape"
        case .server: "server.rack"
        case .libraryPlayback: "music.note.list"
        case .ai: "sparkles"
        case .system: "command"
        case .about: "info.circle"
        }
    }
}

/// 主窗口 / Settings 共享的设置路由：错误恢复可深链到「服务器」分类。
@MainActor
public final class MacSettingsRouter: ObservableObject {
    @Published public var selection: MacSettingsCategory = .general

    public init() {}
}
#endif
