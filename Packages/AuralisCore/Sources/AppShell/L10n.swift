import Foundation

/// 本地化数量辅助：根据 count 返回正确单复数的本地化字符串
/// 使用 String Catalog 的 plural 支持，通过 Bundle.module 查询
enum L10n {
    static func songs(_ count: Int) -> String {
        let format = String(localized: "%lld songs", bundle: .module)
        return String.localizedStringWithFormat(format, count)
    }

    static func artists(_ count: Int) -> String {
        let format = String(localized: "%lld artists", bundle: .module)
        return String.localizedStringWithFormat(format, count)
    }

    static func albums(_ count: Int) -> String {
        let format = String(localized: "%lld albums", bundle: .module)
        return String.localizedStringWithFormat(format, count)
    }

    static func tracksRecentlyAdded(_ count: Int) -> String {
        let format = String(localized: "recently_added_%lld", bundle: .module)
        return String.localizedStringWithFormat(format, count)
    }

    static func playCount(_ count: Int) -> String {
        let format = String(localized: "%lld plays", bundle: .module)
        return String.localizedStringWithFormat(format, count)
    }

    /// 播放所选歌曲数（复数）。英文支持 1/other，繁中不区分。
    static func playSelected(_ count: Int) -> String {
        let format = String(localized: "play_selected_%lld", bundle: .module)
        return String.localizedStringWithFormat(format, count)
    }
}
