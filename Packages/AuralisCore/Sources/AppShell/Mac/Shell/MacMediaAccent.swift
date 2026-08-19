#if os(macOS)
import SwiftUI

/// 统一的 Mac 媒体强调色（接近系统 Music 的 pink/red）。
/// 只定义一次；Normal Player / Full Player 的 active Shuffle / Repeat / Favorite 统一使用。
enum MacMediaAccent {
    /// Music 系 pink/red，Light/Dark 均可用。
    static let color = Color(red: 0.96, green: 0.24, blue: 0.42)
}
#endif