import Foundation

/// 流派显示名本地化：把服务器返回的英文流派名翻译成当前 App 语言用于展示。
/// 只影响显示，不影响「按流派筛选」——筛选仍使用原始流派名（Genre.name）。
///
/// 模型：
/// 服务器原始 Genre → normalize/alias → canonical id → localized display name → UI
/// 例如 rock → genre.rock → zh-Hans:摇滚 / zh-Hant:搖滾 / en:Rock
/// 未知流派直接保留服务器原始值，不做机器翻译。
public enum GenreLocalization {
    /// 别名归一：把不同写法映射到同一 canonical id
    private static let aliases: [String: String] = [
        "hip hop": "hip_hop",
        "hip-hop": "hip_hop",
        "r&b": "rnb",
        "rnb": "rnb",
        "drum and bass": "drum_and_bass",
        "drum & bass": "drum_and_bass",
        "rock and roll": "rock_and_roll",
        "rock & roll": "rock_and_roll",
        "children's": "children",
        "lo-fi": "lofi",
        "world music": "world",
        "synth pop": "synth_pop",
        "alt rock": "alt_rock",
        "indie rock": "indie_rock",
        "post-rock": "post_rock",
        "punk rock": "punk_rock",
        "post-punk": "post_punk",
        "new wave": "new_wave",
        "indie pop": "indie_pop",
        "math rock": "math_rock",
        "noise rock": "noise_rock",
        "southern rock": "southern_rock",
        "blues rock": "blues_rock",
        "folk rock": "folk_rock",
        "jazz rock": "jazz_rock",
        "glam rock": "glam_rock",
        "techno house": "techno_house",
        "deep house": "deep_house",
        "progressive house": "progressive_house",
        "uk garage": "uk_garage",
        "trip-hop": "trip_hop",
        "jazz fusion": "jazz_fusion",
        "smooth jazz": "smooth_jazz",
        "bossa nova": "bossa_nova",
        "big band": "big_band",
        "cool jazz": "cool_jazz",
        "free jazz": "free_jazz",
        "latin jazz": "latin_jazz",
        "soul jazz": "soul_jazz",
        "delta blues": "delta_blues",
        "chicago blues": "chicago_blues",
        "city pop": "city_pop",
        "8-bit": "8bit",
        "avant-garde": "avant_garde",
        "spoken word": "spoken_word",
        "soundtrackscore": "soundtrackscore",
    ]

    /// 已知的 canonical id 集合（与 Domain/Resources/Localizable.xcstrings 的 genre.* 键一一对应）
    private static let knownCanonicals: Set<String> = [
        "pop", "rock", "jazz", "classical", "electronic", "ambient", "hip_hop", "rap", "rnb", "blues",
        "country", "folk", "metal", "punk", "reggae", "soul", "funk", "disco", "house", "techno",
        "trance", "dubstep", "dance", "drum_and_bass", "indie", "indie_rock", "alternative", "alt_rock",
        "acoustic", "easy_listening", "new_age", "instrumental", "soundtrack", "score", "children", "latin",
        "gospel", "celtic", "world", "lofi", "chiptune", "8bit", "synthwave", "vaporwave", "city_pop",
        "mandopop", "cantopop", "k_pop", "j_pop", "anime", "j_rock", "rock_and_roll", "soft_rock",
        "hard_rock", "progressive_rock", "psychedelic", "psychedelic_rock", "emo", "grunge", "shoegaze",
        "dream_pop", "post_rock", "art_rock", "garage_rock", "punk_rock", "post_punk", "new_wave",
        "britpop", "indie_pop", "math_rock", "noise_rock", "southern_rock", "blues_rock", "folk_rock",
        "jazz_rock", "glam_rock", "ska", "techno_house", "deep_house", "progressive_house", "minimal",
        "electro", "idm", "breakbeat", "garage", "uk_garage", "jungle", "downtempo", "trip_hop",
        "chillout", "lounge", "synth_pop", "electropop", "darkwave", "ebm", "industrial", "drumstep",
        "glitch", "jazz_fusion", "smooth_jazz", "bossa_nova", "swing", "big_band", "bebop", "cool_jazz",
        "free_jazz", "latin_jazz", "soul_jazz", "delta_blues", "chicago_blues", "americana", "bluegrass",
        "traditional", "flamenco", "tango", "salsa", "bossa", "afrobeat", "reggaeton", "cumbia", "opera",
        "choral", "musicals", "musical", "baroque", "romantic", "contemporary", "avant_garde", "experimental",
        "spoken_word", "comedy", "holiday", "christmas", "seasonal", "karaoke", "live", "remix", "cover",
        "ballad", "romance", "soundtrackscore",
    ]

    /// 流派英文名 → 本地化显示名；未知流派原样返回（保留服务器原始值）。
    public static func displayName(for name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return name }
        let lower = trimmed.lowercased()

        // 1. 别名归一或直接匹配 canonical
        let canonical: String?
        if let aliased = aliases[lower] {
            canonical = aliased
        } else {
            // 将原始写法规范为 canonical 形式（空格/连字符 → 下划线等）
            var normalized = lower
                .replacingOccurrences(of: " & ", with: "_and_")
                .replacingOccurrences(of: "&", with: "and")
            normalized = normalized
                .replacingOccurrences(of: " ", with: "_")
                .replacingOccurrences(of: "-", with: "_")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "'", with: "")
            while normalized.contains("__") {
                normalized = normalized.replacingOccurrences(of: "__", with: "_")
            }
            if knownCanonicals.contains(normalized) {
                canonical = normalized
            } else if knownCanonicals.contains(lower.replacingOccurrences(of: " ", with: "_")) {
                canonical = lower.replacingOccurrences(of: " ", with: "_")
            } else {
                canonical = nil
            }
        }

        guard let canonical, knownCanonicals.contains(canonical) else {
            // 未知流派：保留服务器原始值，不做翻译
            return trimmed
        }

        let key = "genre.\(canonical)"
        // 使用 Domain Bundle 的 String Catalog；找不到则回退到原始值
        // bundle: .module 在 Swift Package 中指向正确资源包
        let localized = Bundle.module.localizedString(forKey: key, value: trimmed, table: "Localizable")
        return localized
    }
}