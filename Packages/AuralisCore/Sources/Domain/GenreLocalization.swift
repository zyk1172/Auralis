import Foundation

/// 流派显示名本地化：把服务器返回的英文流派名翻译成中文用于展示。
/// 只影响显示，不影响「按流派筛选」——筛选仍使用原始流派名（Genre.name）。
public enum GenreLocalization {
    private static let table: [String: String] = [
        // 主流
        "pop": "流行", "rock": "摇滚", "jazz": "爵士", "classical": "古典",
        "electronic": "电子", "ambient": "氛围", "hip hop": "嘻哈", "hip-hop": "嘻哈",
        "rap": "说唱", "rnb": "节奏布鲁斯", "r&b": "节奏布鲁斯", "blues": "蓝调",
        "country": "乡村", "folk": "民谣", "metal": "金属", "punk": "朋克",
        "reggae": "雷鬼", "soul": "灵魂乐", "funk": "放克", "disco": "迪斯科",
        "house": "浩室", "techno": "科技舞曲", "trance": "迷幻舞曲", "dubstep": "回响贝斯",
        "dance": "舞曲", "drum and bass": "鼓打贝斯", "drum & bass": "鼓打贝斯",
        "indie": "独立", "indie rock": "独立摇滚", "alternative": "另类", "alt rock": "另类摇滚",
        "acoustic": "原声", "easy listening": "轻音乐", "new age": "新世纪",
        "instrumental": "器乐", "soundtrack": "原声带", "score": "影视配乐",
        "children": "儿歌", "children's": "儿歌", "latin": "拉丁", "gospel": "福音",
        "celtic": "凯尔特", "world": "世界音乐", "world music": "世界音乐",
        "lo-fi": "低保真", "lofi": "低保真", "chiptune": "芯片音乐", "8-bit": "8-bit",
        "synthwave": "合成器浪潮", "vaporwave": "蒸汽波", "city pop": "城市流行",
        "mandopop": "华语流行", "cantopop": "粤语流行", "k-pop": "韩语流行",
        "j-pop": "日语流行", "anime": "动漫", "j-rock": "日系摇滚",
        // 摇滚细分
        "rock and roll": "摇滚乐", "rock & roll": "摇滚乐", "soft rock": "软摇滚",
        "hard rock": "硬摇滚", "progressive rock": "前卫摇滚", "psychedelic": "迷幻",
        "psychedelic rock": "迷幻摇滚", "emo": "情绪摇滚", "grunge": "垃圾摇滚",
        "shoegaze": "自赏", "dream pop": "梦幻流行", "post-rock": "后摇滚",
        "art rock": "艺术摇滚", "garage rock": "车库摇滚", "punk rock": "朋克摇滚",
        "post-punk": "后朋克", "new wave": "新浪潮", "britpop": "英伦摇滚",
        "indie pop": "独立流行", "math rock": "数学摇滚", "noise rock": "噪音摇滚",
        "southern rock": "南方摇滚", "blues rock": "蓝调摇滚", "folk rock": "民谣摇滚",
        "jazz rock": "爵士摇滚", "glam rock": "华丽摇滚", "ska": "斯卡",
        // 电子细分
        "techno house": "科技浩室", "deep house": "深浩室", "progressive house": "前卫浩室",
        "minimal": "极简", "electro": "电子放克", "idm": "智能舞曲", "breakbeat": "碎拍",
        "garage": "车库", "uk garage": "英式车库", "jungle": "丛林舞曲",
        "downtempo": "缓拍", "trip-hop": "神游舞曲", "chillout": "弛放", "lounge": "沙发音乐",
        "synth pop": "合成器流行", "electropop": "电子流行", "darkwave": "暗潮",
        "ebm": "电子体乐", "industrial": "工业", "drumstep": "鼓打回响", "glitch": "故障电子",
        // 爵士/布鲁斯细分
        "jazz fusion": "融合爵士", "smooth jazz": "舒缓爵士", "bossa nova": "波萨诺瓦",
        "swing": "摇摆乐", "big band": "大乐队", "bebop": "比波普", "cool jazz": "冷爵士",
        "free jazz": "自由爵士", "latin jazz": "拉丁爵士", "soul jazz": "灵魂爵士",
        "delta blues": "三角洲蓝调", "chicago blues": "芝加哥蓝调",
        // 民谣/世界
        "americana": "美式民谣", "bluegrass": "蓝草", "traditional": "传统",
        "flamenco": "弗拉门戈", "tango": "探戈", "salsa": "萨尔萨", "bossa": "波萨",
        "afrobeat": "非洲节拍", "reggaeton": "雷鬼顿", "cumbia": "昆比亚",
        // 其他
        "opera": "歌剧", "choral": "合唱", "musicals": "音乐剧", "musical": "音乐剧",
        "baroque": "巴洛克", "romantic": "浪漫主义", "contemporary": "当代",
        "avant-garde": "先锋", "experimental": "实验", "spoken word": "朗诵",
        "comedy": "喜剧", "holiday": "节日", "christmas": "圣诞", "seasonal": "季节",
        "karaoke": "卡拉OK", "live": "现场", "remix": "混音", "cover": "翻唱",
        "ballad": "抒情", "romance": "浪漫", "soundtrackscore": "原声带",
    ]

    /// 流派英文名 → 中文显示名；未知流派原样返回。
    public static func displayName(for name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return name }
        let key = trimmed.lowercased()
        if let mapped = table[key] { return mapped }
        // 多词流派：先查整体，再尝试按“主流派 + 细分”逐词回退（如 “Synth-Pop”）。
        for word in trimmed.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "/" }) {
            if let mapped = table[word.lowercased()] {
                return mapped
            }
        }
        return trimmed
    }
}
