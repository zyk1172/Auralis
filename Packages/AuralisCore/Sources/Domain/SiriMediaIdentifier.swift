// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
import Foundation

/// Siri 媒体解析的占位标识。
///
/// 用户只说「播放音乐」时，`INPlayMediaIntent.mediaSearch` 没有具体查询文本；
/// Intents 扩展会返回一个 `INMediaItem`，其 identifier 使用本占位值，
/// 主 App 据此走「播放音乐」分支，而不是尝试按名字匹配一首歌。
///
/// 放在 Domain 里由 App 与 Intents 扩展共享，避免两处字面量漂移后静默失效。
public enum SiriMediaIdentifier {
    public static let playAll = "auralis-play-all"
}
