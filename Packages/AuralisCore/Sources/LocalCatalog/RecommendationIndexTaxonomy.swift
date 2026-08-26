import Foundation

/// Stable, immutable fixed-tag taxonomy for Auralis Recommendation Index.
///
/// AI classification is allowed only to choose from these tags. Nothing in the
/// runtime, provider schema, catalog writer, or Agent tooling may create a new
/// tag at runtime.
public struct TagID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

public enum TagDimension: String, Codable, CaseIterable, Sendable, Hashable {
    case mood
    case scene
    case theme
    case genre
    case style
    case vocal
    case instrument
    case texture
    case rhythm

    public var displayName: String {
        switch self {
        case .mood: "情绪"
        case .scene: "场景"
        case .theme: "主题"
        case .genre: "类型"
        case .style: "风格"
        case .vocal: "人声"
        case .instrument: "乐器"
        case .texture: "质感"
        case .rhythm: "节奏"
        }
    }
}

public struct TagDefinition: Identifiable, Hashable, Sendable, Codable {
    public let id: TagID
    public let dimension: TagDimension
    public let displayName: String
    public let aliases: [String]

    public init(
        id: TagID,
        dimension: TagDimension,
        displayName: String,
        aliases: [String] = []
    ) {
        self.id = id
        self.dimension = dimension
        self.displayName = displayName
        self.aliases = aliases
    }
}

public enum RecommendationIndexTaxonomy {
    public static let all: [TagDefinition] = {
        var result: [TagDefinition] = []
        result.append(contentsOf: moods)
        result.append(contentsOf: scenes)
        result.append(contentsOf: themes)
        result.append(contentsOf: genres)
        result.append(contentsOf: styles)
        result.append(contentsOf: vocals)
        result.append(contentsOf: instruments)
        result.append(contentsOf: textures)
        result.append(contentsOf: rhythms)
        return result
    }()

    public static let byID: [TagID: TagDefinition] = Dictionary(
        uniqueKeysWithValues: all.map { ($0.id, $0) }
    )

    public static let byDimension: [TagDimension: [TagDefinition]] = Dictionary(
        grouping: all,
        by: \.dimension
    )

    public static let displayIndex: [String: TagDefinition] = {
        var index: [String: TagDefinition] = [:]
        for tag in all {
            index[normalize(tag.displayName)] = tag
        }
        return index
    }()

    public static let aliasIndex: [String: TagDefinition] = {
        var index: [String: TagDefinition] = [:]
        for tag in all {
            for alias in tag.aliases {
                index[normalize(alias)] = tag
            }
        }
        return index
    }()

    public static func resolve(_ raw: String) -> TagDefinition? {
        let normalized = normalize(raw)
        let id = TagID(rawValue: raw)
        if let byExactID = byID[id] {
            return byExactID
        }
        return displayIndex[normalized] ?? aliasIndex[normalized]
    }

    public static func displayName(for id: TagID) -> String? {
        byID[id]?.displayName
    }

    public static func ids(for dimension: TagDimension) -> [TagID] {
        (byDimension[dimension] ?? []).map(\.id).sorted { $0.rawValue < $1.rawValue }
    }

    public static func definitions(for dimension: TagDimension) -> [TagDefinition] {
        (byDimension[dimension] ?? []).sorted { $0.id.rawValue < $1.id.rawValue }
    }

    /// Compact search used by Agent taxonomy discovery. It resolves aliases,
    /// display names, prefix matches, and substring matches with stable order.
    public static func search(_ query: String, limit: Int = 12) -> [TagDefinition] {
        let needle = normalize(query)
        guard !needle.isEmpty else { return [] }
        let exact = displayIndex[needle] ?? aliasIndex[needle]
        var ranked: [(score: Int, tag: TagDefinition)] = []
        if let exact {
            ranked.append((0, exact))
        }
        for tag in all {
            if ranked.contains(where: { $0.tag.id == tag.id }) { continue }
            let display = normalize(tag.displayName)
            let id = normalize(tag.id.rawValue)
            if display.hasPrefix(needle) || id.hasPrefix(needle) {
                ranked.append((1, tag))
            } else if display.contains(needle) || id.contains(needle) {
                ranked.append((2, tag))
            } else if tag.aliases.contains(where: { normalize($0).contains(needle) }) {
                ranked.append((3, tag))
            }
        }
        return ranked.sorted {
            if $0.score != $1.score { return $0.score < $1.score }
            return $0.tag.id.rawValue < $1.tag.id.rawValue
        }.prefix(max(1, min(limit, 50))).map(\.tag)
    }

    public static func validate() -> [String] {
        var issues: [String] = []
        var seenIDs = Set<TagID>()
        var seenByDimension = [TagDimension: Set<String>]()
        var seenAlias = [String: TagID]()
        for tag in all {
            if tag.id.rawValue.isEmpty {
                issues.append("empty id")
                continue
            }
            if !tag.id.rawValue.hasPrefix("\(tag.dimension.rawValue).") {
                issues.append("\(tag.id.rawValue) namespace mismatch")
            }
            if tag.displayName.isEmpty {
                issues.append("\(tag.id.rawValue) empty display")
            }
            if !seenIDs.insert(tag.id).inserted {
                issues.append("duplicate id \(tag.id.rawValue)")
            }
            let displayKey = normalize(tag.displayName)
            if !seenByDimension[tag.dimension, default: []].insert(displayKey).inserted {
                issues.append("duplicate display \(tag.displayName) in \(tag.dimension.rawValue)")
            }
            for alias in tag.aliases {
                let key = normalize(alias)
                if let previous = seenAlias[key] {
                    issues.append("alias \(alias) maps to both \(previous.rawValue) and \(tag.id.rawValue)")
                } else {
                    seenAlias[key] = tag.id
                }
            }
        }
        return issues
    }

    private static func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")
    }

    private static func mood(_ suffix: String, _ display: String, aliases: [String] = []) -> TagDefinition {
        TagDefinition(id: TagID(rawValue: "mood.\(suffix)"), dimension: .mood, displayName: display, aliases: aliases)
    }

    private static func scene(_ suffix: String, _ display: String, aliases: [String] = []) -> TagDefinition {
        TagDefinition(id: TagID(rawValue: "scene.\(suffix)"), dimension: .scene, displayName: display, aliases: aliases)
    }

    private static func theme(_ suffix: String, _ display: String, aliases: [String] = []) -> TagDefinition {
        TagDefinition(id: TagID(rawValue: "theme.\(suffix)"), dimension: .theme, displayName: display, aliases: aliases)
    }

    private static func genre(_ suffix: String, _ display: String, aliases: [String] = []) -> TagDefinition {
        TagDefinition(id: TagID(rawValue: "genre.\(suffix)"), dimension: .genre, displayName: display, aliases: aliases)
    }

    private static func style(_ suffix: String, _ display: String, aliases: [String] = []) -> TagDefinition {
        TagDefinition(id: TagID(rawValue: "style.\(suffix)"), dimension: .style, displayName: display, aliases: aliases)
    }

    private static func vocal(_ suffix: String, _ display: String, aliases: [String] = []) -> TagDefinition {
        TagDefinition(id: TagID(rawValue: "vocal.\(suffix)"), dimension: .vocal, displayName: display, aliases: aliases)
    }

    private static func instrument(_ suffix: String, _ display: String, aliases: [String] = []) -> TagDefinition {
        TagDefinition(id: TagID(rawValue: "instrument.\(suffix)"), dimension: .instrument, displayName: display, aliases: aliases)
    }

    private static func texture(_ suffix: String, _ display: String, aliases: [String] = []) -> TagDefinition {
        TagDefinition(id: TagID(rawValue: "texture.\(suffix)"), dimension: .texture, displayName: display, aliases: aliases)
    }

    private static func rhythm(_ suffix: String, _ display: String, aliases: [String] = []) -> TagDefinition {
        TagDefinition(id: TagID(rawValue: "rhythm.\(suffix)"), dimension: .rhythm, displayName: display, aliases: aliases)
    }

    private static let moods: [TagDefinition] = [
        mood("calm", "平静", aliases: ["安静"]),
        mood("peaceful", "宁静"),
        mood("serene", "平和"),
        mood("relaxed", "放松", aliases: ["轻松"]),
        mood("soothing", "舒缓"),
        mood("healing", "治愈"),
        mood("comforting", "安慰"),
        mood("warm", "温暖"),
        mood("soft", "柔和"),
        mood("light", "轻盈"),
        mood("fresh", "清新"),
        mood("cozy", "惬意"),
        mood("languid", "慵懒"),
        mood("leisurely", "闲适"),
        mood("restrained", "克制"),
        mood("quiet", "沉静"),
        mood("bright", "明亮"),
        mood("sunny", "阳光"),
        mood("happy", "快乐"),
        mood("joyful", "欢乐"),
        mood("delight", "喜悦"),
        mood("excited", "兴奋"),
        mood("ecstatic", "狂喜"),
        mood("uplifting", "振奋"),
        mood("inspiring", "鼓舞"),
        mood("hopeful", "希望"),
        mood("optimistic", "乐观"),
        mood("confident", "自信"),
        mood("unfettered", "洒脱"),
        mood("free", "自由"),
        mood("brisk", "爽快"),
        mood("lively", "活泼"),
        mood("playful", "俏皮"),
        mood("cute", "可爱"),
        mood("sweet", "甜蜜"),
        mood("romantic", "浪漫"),
        mood("affectionate", "深情"),
        mood("tender", "温柔"),
        mood("intimate", "亲密"),
        mood("sensual", "感性"),
        mood("sexy", "性感"),
        mood("seductive", "诱惑"),
        mood("passionate_love", "热恋"),
        mood("cherishing", "眷恋"),
        mood("yearning", "思念"),
        mood("nostalgic", "怀旧"),
        mood("melancholic", "惆怅"),
        mood("bittersweet", "苦涩"),
        mood("sad", "悲伤", aliases: ["伤感"]),
        mood("gloomy", "忧郁"),
        mood("lonely", "孤独"),
        mood("lost", "失落"),
        mood("heartbroken", "心碎"),
        mood("mournful", "哀伤"),
        mood("grieving", "哀悼"),
        mood("bleak", "悲凉"),
        mood("desolate", "苍凉"),
        mood("helpless", "无奈"),
        mood("tired", "疲惫"),
        mood("dark", "黑暗"),
        mood("oppressive", "压抑"),
        mood("despairing", "绝望"),
        mood("cold", "冷冽"),
        mood("detached", "疏离"),
        mood("hollow", "空洞"),
        mood("heavy", "沉重"),
        mood("sinister", "肃杀"),
        mood("introspective", "内省"),
        mood("contemplative", "沉思"),
        mood("reflective", "反思"),
        mood("reconciled", "释然"),
        mood("philosophical", "哲思"),
        mood("profound", "深邃"),
        mood("earnest", "认真"),
        mood("sensitive", "敏感"),
        mood("fragile", "脆弱"),
        mood("solemn", "庄严"),
        mood("sacred", "神圣", aliases: ["圣洁", "庄严神圣"]),
        mood("sublime", "崇高"),
        mood("epic", "史诗"),
        mood("grand", "宏大"),
        mood("heroic", "英雄"),
        mood("triumphant", "胜利"),
        mood("steadfast", "坚定"),
        mood("majestic", "壮阔"),
        mood("tragic_heroic", "悲壮"),
        mood("awe", "敬畏"),
        mood("fervent", "热烈"),
        mood("fiery", "激情"),
        mood("intense", "强烈"),
        mood("rousing", "激昂"),
        mood("burning", "燃"),
        mood("urgent", "急迫"),
        mood("restless", "躁动"),
        mood("wild", "狂野"),
        mood("explosive", "爆发"),
        mood("cathartic", "宣泄"),
        mood("tense", "紧张"),
        mood("anxious", "焦虑"),
        mood("uneasy", "不安"),
        mood("suspenseful", "悬疑"),
        mood("dangerous", "危险"),
        mood("pressured", "压迫"),
        mood("fearful", "恐惧"),
        mood("horror", "惊悚"),
        mood("eerie", "诡异"),
        mood("haunting", "阴森"),
        mood("threatening", "威胁"),
        mood("mysterious", "神秘"),
        mood("ethereal", "空灵"),
        mood("dreamy", "梦幻"),
        mood("hazy", "迷离"),
        mood("hypnotic", "催眠"),
        mood("psychedelic", "迷幻"),
        mood("surreal", "超现实"),
        mood("fantastical", "奇幻"),
        mood("magical", "魔幻"),
        mood("futuristic", "未来感"),
        mood("cosmic", "宇宙感"),
        mood("angry", "愤怒"),
        mood("aggressive", "攻击性"),
        mood("radical", "激进"),
        mood("rebellious", "叛逆"),
        mood("provocative", "挑衅"),
        mood("hostile", "敌意"),
        mood("gritty", "粗粝"),
        mood("ferocious", "凶猛"),
        mood("violent", "暴烈"),
        mood("chaotic", "混乱"),
        mood("dramatic", "戏剧化"),
        mood("glamorous", "华丽"),
        mood("exaggerated", "夸张"),
        mood("festive", "庆典感"),
        mood("ceremonial", "仪式感"),
        mood("witty", "戏谑"),
        mood("humorous", "幽默"),
        mood("absurd", "荒诞"),
    ]

    private static let scenes: [TagDefinition] = [
        scene("early_morning", "清晨"),
        scene("morning", "早晨"),
        scene("late_morning", "上午"),
        scene("noon", "午间"),
        scene("afternoon", "午后"),
        scene("dusk", "黄昏"),
        scene("evening", "傍晚"),
        scene("night", "夜晚"),
        scene("late_night", "深夜", aliases: ["晚上", "夜间"]),
        scene("pre_dawn", "凌晨"),
        scene("bedtime", "睡前"),
        scene("waking_up", "起床"),
        scene("commute", "通勤", aliases: ["上班路上", "下班路上"]),
        scene("work", "工作"),
        scene("office", "办公"),
        scene("study", "学习"),
        scene("focus", "专注"),
        scene("reading", "阅读"),
        scene("writing", "写作"),
        scene("coding", "编程", aliases: ["写代码"]),
        scene("exam", "做题"),
        scene("creative_work", "创作"),
        scene("drawing", "画画"),
        scene("background", "背景音乐"),
        scene("work_break", "工作休息"),
        scene("study_sprint", "学习冲刺"),
        scene("home", "居家", aliases: ["在家", "一个人在家"]),
        scene("cooking", "做饭"),
        scene("dining", "吃饭"),
        scene("breakfast", "早餐"),
        scene("lunch", "午餐"),
        scene("dinner", "晚餐"),
        scene("cleaning", "清洁"),
        scene("housework", "家务"),
        scene("organizing", "整理房间"),
        scene("shower", "洗澡"),
        scene("bath", "泡澡"),
        scene("daydreaming", "发呆"),
        scene("nap", "午休"),
        scene("siesta", "小憩"),
        scene("meditation", "冥想"),
        scene("yoga", "瑜伽"),
        scene("stretching", "拉伸"),
        scene("sleeping", "睡眠"),
        scene("getting_ready", "起床准备"),
        scene("walking", "散步"),
        scene("city_walk", "城市漫步"),
        scene("park", "公园"),
        scene("hiking", "徒步"),
        scene("mountaineering", "登山"),
        scene("camping", "露营"),
        scene("seaside", "海边"),
        scene("wilderness", "山野"),
        scene("outdoor", "户外"),
        scene("sunset_viewing", "看日落"),
        scene("stargazing", "看星空"),
        scene("running", "跑步"),
        scene("night_running", "夜跑"),
        scene("fitness", "健身"),
        scene("strength_training", "力量训练", aliases: ["撸铁"]),
        scene("cardio", "有氧运动"),
        scene("cycling", "骑行"),
        scene("warmup", "热身"),
        scene("sprint", "运动冲刺"),
        scene("recovery", "运动恢复"),
        scene("driving", "驾车", aliases: ["开车"]),
        scene("night_driving", "夜间驾车", aliases: ["开夜车"]),
        scene("long_drive", "长途驾车"),
        scene("road_trip", "公路旅行"),
        scene("subway", "地铁"),
        scene("bus", "公交"),
        scene("train", "火车"),
        scene("high_speed_rail", "高铁"),
        scene("flight", "飞行"),
        scene("waiting", "候机"),
        scene("travel", "旅行"),
        scene("friends_gathering", "朋友小聚"),
        scene("family_gathering", "家庭聚会"),
        scene("party", "聚会"),
        scene("club", "派对"),
        scene("nightclub", "夜店"),
        scene("bar", "酒吧"),
        scene("cafe", "咖啡馆"),
        scene("afternoon_tea", "下午茶"),
        scene("date", "约会"),
        scene("romantic_dinner", "浪漫晚餐"),
        scene("wedding", "婚礼"),
        scene("birthday", "生日"),
        scene("celebration", "庆祝"),
        scene("holiday", "节日"),
        scene("rainy", "雨天", aliases: ["下雨", "下雨天"]),
        scene("storm", "暴雨"),
        scene("overcast", "阴天"),
        scene("cloudy", "多云"),
        scene("sunny", "晴天"),
        scene("snowy", "雪天"),
        scene("foggy", "雾天"),
        scene("thunder", "雷雨"),
        scene("hot_weather", "炎热天气"),
        scene("cold_weather", "寒冷天气"),
        scene("spring", "春日"),
        scene("summer", "夏日"),
        scene("autumn", "秋日"),
        scene("winter", "冬日"),
        scene("bedroom", "卧室"),
        scene("living_room", "客厅"),
        scene("library", "图书馆"),
        scene("city_night", "城市夜景"),
    ]

    private static let themes: [TagDefinition] = [
        theme("love", "爱情"),
        theme("new_love", "新恋情"),
        theme("infatuation", "热恋"),
        theme("confession", "告白"),
        theme("dating", "约会"),
        theme("intimacy", "亲密关系"),
        theme("ambiguity", "暧昧"),
        theme("unrequited_love", "单恋"),
        theme("breakup", "失恋"),
        theme("separation", "分手"),
        theme("heartache", "心碎"),
        theme("longing", "思念"),
        theme("reunion", "重逢"),
        theme("farewell", "告别"),
        theme("friendship", "友情"),
        theme("family", "家庭"),
        theme("kinship", "亲情"),
        theme("youth", "青春"),
        theme("growth", "成长"),
        theme("adulthood", "成年"),
        theme("memories", "回忆"),
        theme("past", "怀念过去"),
        theme("hometown", "故乡"),
        theme("nostalgia", "乡愁"),
        theme("solitude_companion", "孤独陪伴", aliases: ["一个人", "独处"]),
        theme("self_healing", "自我疗愈"),
        theme("self_acceptance", "自我接纳"),
        theme("comfort", "安慰"),
        theme("emptiness", "放空"),
        theme("reflection", "反思"),
        theme("self_examination", "自省"),
        theme("new_beginning", "重新开始"),
        theme("hope", "希望"),
        theme("freedom", "自由"),
        theme("dreams", "梦想"),
        theme("adventure", "冒险"),
        theme("travel_longing", "旅行向往"),
        theme("city_life", "城市生活"),
        theme("nature", "自然"),
        theme("future", "未来"),
        theme("technology", "科技"),
        theme("cosmos", "宇宙"),
        theme("dreamland", "梦境"),
        theme("fantasy", "幻想"),
        theme("religion", "宗教"),
        theme("faith", "信仰"),
        theme("spirituality", "灵性"),
        theme("celebration", "庆祝"),
        theme("victory", "胜利"),
        theme("graduation", "毕业"),
        theme("wedding", "婚礼"),
        theme("festival", "节日"),
        theme("sports_motivation", "运动动力"),
        theme("work_motivation", "工作动力"),
        theme("study_motivation", "学习动力"),
        theme("alertness", "清醒提神"),
        theme("sleep_aid", "助眠"),
        theme("emotional_release", "情绪释放"),
        theme("anger_release", "愤怒释放"),
        theme("sadness_companion", "悲伤陪伴"),
        theme("background_companion", "背景陪伴"),
        theme("party_excitement", "派对狂欢"),
        theme("romantic_mood", "浪漫氛围"),
        theme("sensual_mood", "性感氛围"),
        theme("cinematic", "电影感"),
        theme("epic_narrative", "史诗叙事"),
        theme("heroic_narrative", "英雄叙事"),
        theme("social_observation", "社会观察"),
        theme("rebellion", "反抗"),
        theme("resistance", "抗争"),
        theme("peace", "和平"),
        theme("war", "战争"),
        theme("death", "死亡"),
        theme("life", "生命"),
        theme("time", "时间"),
        theme("memory", "记忆"),
    ]

    private static let genres: [TagDefinition] = [
        genre("pop", "流行"),
        genre("rock", "摇滚"),
        genre("electronic", "电子音乐", aliases: ["电子"]),
        genre("hip_hop", "嘻哈", aliases: ["hiphop", "hip-hop", "说唱"]),
        genre("r_and_b_soul", "R&B / Soul"),
        genre("jazz", "爵士"),
        genre("classical", "古典音乐", aliases: ["古典"]),
        genre("folk", "民谣 / Singer-Songwriter", aliases: ["民谣"]),
        genre("metal", "金属"),
        genre("punk", "朋克"),
        genre("blues", "蓝调"),
        genre("country", "乡村"),
        genre("funk", "放克"),
        genre("disco", "迪斯科 / 舞曲", aliases: ["舞曲"]),
        genre("reggae", "雷鬼 / Jamaican", aliases: ["雷鬼"]),
        genre("latin", "拉丁"),
        genre("world", "世界音乐"),
        genre("traditional", "传统 / 民族音乐"),
        genre("ambient", "Ambient / New Age"),
        genre("soundtrack", "Soundtrack / 配乐", aliases: ["原声带"]),
        genre("experimental", "实验 / 先锋"),
        genre("gospel", "宗教 / Gospel"),
        genre("children", "儿童音乐"),
        genre("comedy", "喜剧 / Novelty"),
        genre("musical", "音乐剧"),
        genre("chinese_opera", "戏曲 / 曲艺"),
    ]

    private static let styles: [TagDefinition] = [
        style("dance_pop", "Dance Pop"),
        style("synth_pop", "Synth-pop"),
        style("electropop", "Electropop"),
        style("indie_pop", "Indie Pop"),
        style("art_pop", "Art Pop"),
        style("dream_pop", "Dream Pop"),
        style("chamber_pop", "Chamber Pop"),
        style("baroque_pop", "Baroque Pop"),
        style("power_pop", "Power Pop"),
        style("pop_rock", "Pop Rock"),
        style("teen_pop", "Teen Pop"),
        style("adult_contemporary", "Adult Contemporary"),
        style("sophisti_pop", "Sophisti-pop"),
        style("city_pop", "City Pop"),
        style("j_pop", "J-Pop"),
        style("k_pop", "K-Pop"),
        style("c_pop", "C-Pop"),
        style("mandopop", "Mandopop"),
        style("cantopop", "Cantopop"),
        style("sunshine_pop", "Sunshine Pop"),
        style("psychedelic_pop", "Psychedelic Pop"),
        style("hyperpop", "Hyperpop"),
        style("bedroom_pop", "Bedroom Pop"),
        style("bubblegum_pop", "Bubblegum Pop"),
        style("folk_pop", "Folk Pop"),
        style("pop_rap", "Pop Rap"),
        style("alternative_pop", "Alternative Pop"),
        style("indietronica", "Indietronica"),
        style("classic_rock", "Classic Rock"),
        style("alternative_rock", "Alternative Rock"),
        style("indie_rock", "Indie Rock"),
        style("art_rock", "Art Rock"),
        style("progressive_rock", "Progressive Rock"),
        style("psychedelic_rock", "Psychedelic Rock"),
        style("hard_rock", "Hard Rock"),
        style("soft_rock", "Soft Rock"),
        style("arena_rock", "Arena Rock"),
        style("garage_rock", "Garage Rock"),
        style("glam_rock", "Glam Rock"),
        style("blues_rock", "Blues Rock"),
        style("folk_rock", "Folk Rock"),
        style("country_rock", "Country Rock"),
        style("southern_rock", "Southern Rock"),
        style("surf_rock", "Surf Rock"),
        style("post_rock", "Post-Rock"),
        style("math_rock", "Math Rock"),
        style("noise_rock", "Noise Rock"),
        style("shoegaze", "Shoegaze"),
        style("grunge", "Grunge"),
        style("britpop", "Britpop"),
        style("gothic_rock", "Gothic Rock"),
        style("stoner_rock", "Stoner Rock"),
        style("krautrock", "Krautrock"),
        style("rockabilly", "Rockabilly"),
        style("experimental_rock", "Experimental Rock"),
        style("space_rock", "Space Rock"),
        style("post_grunge", "Post-Grunge"),
        style("punk_rock", "Punk Rock"),
        style("pop_punk", "Pop Punk"),
        style("post_punk", "Post-Punk"),
        style("hardcore_punk", "Hardcore Punk"),
        style("post_hardcore", "Post-Hardcore"),
        style("emo", "Emo"),
        style("screamo", "Screamo"),
        style("skate_punk", "Skate Punk"),
        style("garage_punk", "Garage Punk"),
        style("crust_punk", "Crust Punk"),
        style("anarcho_punk", "Anarcho-Punk"),
        style("oi", "Oi!"),
        style("new_wave", "New Wave"),
        style("no_wave", "No Wave"),
        style("heavy_metal", "Heavy Metal"),
        style("thrash_metal", "Thrash Metal"),
        style("death_metal", "Death Metal"),
        style("melodic_death_metal", "Melodic Death Metal"),
        style("black_metal", "Black Metal"),
        style("doom_metal", "Doom Metal"),
        style("sludge_metal", "Sludge Metal"),
        style("stoner_metal", "Stoner Metal"),
        style("power_metal", "Power Metal"),
        style("symphonic_metal", "Symphonic Metal"),
        style("progressive_metal", "Progressive Metal"),
        style("folk_metal", "Folk Metal"),
        style("gothic_metal", "Gothic Metal"),
        style("nu_metal", "Nu Metal"),
        style("metalcore", "Metalcore"),
        style("deathcore", "Deathcore"),
        style("industrial_metal", "Industrial Metal"),
        style("alternative_metal", "Alternative Metal"),
        style("post_metal", "Post-Metal"),
        style("speed_metal", "Speed Metal"),
        style("glam_metal", "Glam Metal"),
        style("atmospheric_black_metal", "Atmospheric Black Metal"),
        style("technical_death_metal", "Technical Death Metal"),
        style("house", "House"),
        style("deep_house", "Deep House"),
        style("tech_house", "Tech House"),
        style("progressive_house", "Progressive House"),
        style("electro_house", "Electro House"),
        style("future_house", "Future House"),
        style("tropical_house", "Tropical House"),
        style("acid_house", "Acid House"),
        style("techno", "Techno"),
        style("minimal_techno", "Minimal Techno"),
        style("detroit_techno", "Detroit Techno"),
        style("industrial_techno", "Industrial Techno"),
        style("trance", "Trance"),
        style("progressive_trance", "Progressive Trance"),
        style("psytrance", "Psytrance"),
        style("uplifting_trance", "Uplifting Trance"),
        style("drum_and_bass", "Drum & Bass"),
        style("liquid_dnb", "Liquid Drum & Bass"),
        style("jungle", "Jungle"),
        style("breakbeat", "Breakbeat"),
        style("uk_garage", "UK Garage"),
        style("two_step", "2-Step"),
        style("dubstep", "Dubstep"),
        style("future_bass", "Future Bass"),
        style("edm_trap", "EDM Trap"),
        style("hardstyle", "Hardstyle"),
        style("hardcore", "Hardcore"),
        style("gabber", "Gabber"),
        style("ambient", "Ambient"),
        style("dark_ambient", "Dark Ambient"),
        style("downtempo", "Downtempo"),
        style("chillout", "Chillout"),
        style("trip_hop", "Trip-Hop"),
        style("idm", "IDM"),
        style("glitch", "Glitch"),
        style("vaporwave", "Vaporwave"),
        style("synthwave", "Synthwave"),
        style("retrowave", "Retrowave"),
        style("chillwave", "Chillwave"),
        style("drone", "Drone"),
        style("noise", "Noise"),
        style("electro", "Electro"),
        style("ebm", "EBM"),
        style("industrial", "Industrial"),
        style("electronica", "Electronica"),
        style("old_school_hip_hop", "Old School Hip-Hop"),
        style("boom_bap", "Boom Bap"),
        style("trap", "Trap"),
        style("drill", "Drill"),
        style("cloud_rap", "Cloud Rap"),
        style("conscious_hip_hop", "Conscious Hip-Hop"),
        style("alternative_hip_hop", "Alternative Hip-Hop"),
        style("experimental_hip_hop", "Experimental Hip-Hop"),
        style("jazz_rap", "Jazz Rap"),
        style("lofi_hip_hop", "Lo-fi Hip-Hop"),
        style("gangsta_rap", "Gangsta Rap"),
        style("east_coast_hip_hop", "East Coast Hip-Hop"),
        style("west_coast_hip_hop", "West Coast Hip-Hop"),
        style("southern_hip_hop", "Southern Hip-Hop"),
        style("crunk", "Crunk"),
        style("grime", "Grime"),
        style("phonk", "Phonk"),
        style("emo_rap", "Emo Rap"),
        style("contemporary_rnb", "Contemporary R&B"),
        style("alternative_rnb", "Alternative R&B"),
        style("neo_soul", "Neo Soul"),
        style("soul", "Soul"),
        style("motown", "Motown"),
        style("philly_soul", "Philly Soul"),
        style("quiet_storm", "Quiet Storm"),
        style("new_jack_swing", "New Jack Swing"),
        style("funk", "Funk"),
        style("p_funk", "P-Funk"),
        style("funk_rock", "Funk Rock"),
        style("gospel_soul", "Gospel Soul"),
        style("traditional_jazz", "Traditional Jazz"),
        style("dixieland", "Dixieland"),
        style("swing", "Swing"),
        style("big_band", "Big Band"),
        style("bebop", "Bebop"),
        style("hard_bop", "Hard Bop"),
        style("cool_jazz", "Cool Jazz"),
        style("modal_jazz", "Modal Jazz"),
        style("free_jazz", "Free Jazz"),
        style("jazz_fusion", "Jazz Fusion"),
        style("smooth_jazz", "Smooth Jazz"),
        style("latin_jazz", "Latin Jazz"),
        style("afro_cuban_jazz", "Afro-Cuban Jazz"),
        style("vocal_jazz", "Vocal Jazz"),
        style("gypsy_jazz", "Gypsy Jazz"),
        style("nu_jazz", "Nu Jazz"),
        style("acid_jazz", "Acid Jazz"),
        style("jazz_funk", "Jazz-Funk"),
        style("baroque", "Baroque"),
        style("classical_period", "Classical Period"),
        style("romantic", "Romantic"),
        style("modern_classical", "Modern Classical"),
        style("contemporary_classical", "Contemporary Classical"),
        style("minimalism", "Minimalism"),
        style("impressionism", "Impressionism"),
        style("chamber_music", "Chamber Music"),
        style("orchestral", "Orchestral"),
        style("symphony", "Symphony"),
        style("concerto", "Concerto"),
        style("sonata", "Sonata"),
        style("opera", "Opera"),
        style("choral", "Choral"),
        style("sacred_classical", "Sacred Classical"),
        style("solo_piano", "Solo Piano"),
        style("string_quartet", "String Quartet"),
        style("ballet", "Ballet"),
        style("neoclassical", "Neoclassical"),
        style("classical_crossover", "Classical Crossover"),
        style("traditional_folk", "Traditional Folk"),
        style("contemporary_folk", "Contemporary Folk"),
        style("indie_folk", "Indie Folk"),
        style("singer_songwriter", "Singer-Songwriter"),
        style("americana", "Americana"),
        style("bluegrass", "Bluegrass"),
        style("celtic", "Celtic"),
        style("nordic_folk", "Nordic Folk"),
        style("balkan_folk", "Balkan Folk"),
        style("neofolk", "Neofolk"),
        style("traditional_country", "Traditional Country"),
        style("contemporary_country", "Contemporary Country"),
        style("alt_country", "Alt-Country"),
        style("outlaw_country", "Outlaw Country"),
        style("honky_tonk", "Honky Tonk"),
        style("country_pop", "Country Pop"),
        style("delta_blues", "Delta Blues"),
        style("chicago_blues", "Chicago Blues"),
        style("electric_blues", "Electric Blues"),
        style("acoustic_blues", "Acoustic Blues"),
        style("country_blues", "Country Blues"),
        style("soul_blues", "Soul Blues"),
        style("roots_reggae", "Roots Reggae"),
        style("dub", "Dub"),
        style("ska", "Ska"),
        style("rocksteady", "Rocksteady"),
        style("dancehall", "Dancehall"),
        style("ragga", "Ragga"),
        style("two_tone", "2 Tone"),
        style("bossa_nova", "Bossa Nova"),
        style("samba", "Samba"),
        style("salsa", "Salsa"),
        style("tango", "Tango"),
        style("bachata", "Bachata"),
        style("merengue", "Merengue"),
        style("reggaeton", "Reggaeton"),
        style("latin_pop", "Latin Pop"),
        style("latin_rock", "Latin Rock"),
        style("cumbia", "Cumbia"),
        style("mariachi", "Mariachi"),
        style("afrobeat", "Afrobeat"),
        style("afrobeats", "Afrobeats"),
        style("highlife", "Highlife"),
        style("soukous", "Soukous"),
        style("middle_eastern", "Middle Eastern"),
        style("arabic_pop", "Arabic Pop"),
        style("indian_classical", "Indian Classical"),
        style("hindustani", "Hindustani Classical"),
        style("carnatic", "Carnatic"),
        style("bollywood", "Bollywood"),
        style("qawwali", "Qawwali"),
        style("flamenco", "Flamenco"),
        style("fado", "Fado"),
        style("french_chanson", "French Chanson"),
        style("japanese_traditional", "Japanese Traditional"),
        style("korean_traditional", "Korean Traditional"),
        style("chinese_traditional", "Chinese Traditional"),
        style("guofeng", "国风"),
        style("gufeng", "古风"),
        style("minyue", "民乐"),
        style("xiqu", "戏曲"),
        style("mongolian", "蒙古音乐"),
        style("tibetan", "藏族音乐"),
        style("xinjiang", "新疆民族音乐"),
        style("film_score", "Film Score"),
        style("tv_score", "TV Score"),
        style("game_soundtrack", "Game Soundtrack"),
        style("anime_soundtrack", "Anime Soundtrack"),
        style("musical_theatre", "Musical Theatre"),
        style("cinematic", "Cinematic"),
        style("trailer_music", "Trailer Music"),
        style("library_music", "Library Music"),
        style("new_age", "New Age"),
        style("meditation_music", "Meditation Music"),
        style("easy_listening", "Easy Listening"),
        style("lounge", "Lounge"),
        style("exotica", "Exotica"),
        style("christmas", "Christmas"),
        style("childrens_music", "Children's Music"),
        style("comedy_music", "Comedy Music"),
        style("spoken_word", "Spoken Word"),
        style("experimental", "Experimental"),
        style("avant_garde", "Avant-Garde"),
        style("sound_art", "Sound Art"),
    ]

    private static let vocals: [TagDefinition] = [
        vocal("instrumental", "器乐 / 无人声", aliases: ["纯音乐", "无人声", "没有歌词", "无歌词"]),
        vocal("male_lead", "男主唱", aliases: ["男声", "男歌手"]),
        vocal("female_lead", "女主唱", aliases: ["女声", "女歌手"]),
        vocal("mixed_lead", "男女混合主唱"),
        vocal("duet", "对唱"),
        vocal("ensemble", "多人合唱"),
        vocal("choir", "合唱团", aliases: ["合唱"]),
        vocal("children", "童声"),
        vocal("group_vocal", "群体人声"),
        vocal("harmony_prominent", "和声突出"),
        vocal("rap", "说唱", aliases: ["Rap"]),
        vocal("half_sung_half_rap", "半说半唱"),
        vocal("spoken_word", "念白"),
        vocal("recitation", "朗诵"),
        vocal("chant", "吟唱"),
        vocal("a_cappella", "清唱"),
        vocal("whisper", "低语"),
        vocal("breathy", "气声"),
        vocal("falsetto", "假声"),
        vocal("powerful_lead", "高亢唱法"),
        vocal("strong_vocal", "强力唱法"),
        vocal("operatic", "歌剧唱法"),
        vocal("bel_canto", "美声"),
        vocal("soul_vocal", "灵魂唱腔"),
        vocal("melisma", "转音突出"),
        vocal("shout", "呼喊"),
        vocal("scream", "尖叫"),
        vocal("growl", "嘶吼"),
        vocal("harsh_vocal", "Growl"),
        vocal("clean_vocal", "Clean Vocal"),
        vocal("vocoder", "Vocoder / 机器人声"),
        vocal("sampled_vocal", "采样人声"),
        vocal("humming", "哼唱"),
        vocal("call_and_response", "Call and Response"),
    ]

    private static let instruments: [TagDefinition] = [
        instrument("piano", "钢琴"),
        instrument("electric_piano", "电钢琴"),
        instrument("synthesizer", "合成器"),
        instrument("organ", "管风琴"),
        instrument("acoustic_guitar", "木吉他"),
        instrument("electric_guitar", "电吉他"),
        instrument("distorted_guitar", "失真吉他"),
        instrument("bass", "贝斯"),
        instrument("upright_bass", "低音提琴"),
        instrument("drums", "架子鼓"),
        instrument("drum_machine", "鼓机"),
        instrument("percussion", "打击乐"),
        instrument("eight_oh_eight", "808"),
        instrument("violin", "小提琴"),
        instrument("cello", "大提琴"),
        instrument("strings", "弦乐组"),
        instrument("orchestra", "管弦乐团"),
        instrument("trumpet", "小号"),
        instrument("trombone", "长号"),
        instrument("french_horn", "圆号"),
        instrument("brass", "铜管组"),
        instrument("saxophone", "萨克斯"),
        instrument("flute", "长笛"),
        instrument("clarinet", "单簧管"),
        instrument("woodwinds", "木管组"),
        instrument("harp", "竖琴"),
        instrument("accordion", "手风琴"),
        instrument("harmonica", "口琴"),
        instrument("banjo", "班卓"),
        instrument("mandolin", "曼陀林"),
        instrument("ukulele", "尤克里里"),
        instrument("sitar", "西塔琴"),
        instrument("tabla", "塔布拉鼓"),
        instrument("erhu", "二胡"),
        instrument("guzheng", "古筝"),
        instrument("pipa", "琵琶"),
        instrument("dizi", "笛子"),
        instrument("xiao", "箫"),
        instrument("suona", "唢呐"),
        instrument("guqin", "古琴"),
        instrument("yangqin", "扬琴"),
        instrument("chinese_percussion", "民族打击乐"),
        instrument("sampler", "采样器"),
        instrument("turntable", "Turntable / Scratch"),
        instrument("field_recording", "环境采样"),
        instrument("bells", "钟声 / Chime"),
        instrument("marimba", "木琴 / 马林巴"),
    ]

    private static let textures: [TagDefinition] = [
        texture("acoustic", "原声质感"),
        texture("electronic", "电子质感"),
        texture("organic", "有机质感"),
        texture("synthetic", "合成质感"),
        texture("warm", "温暖"),
        texture("cold", "冷色"),
        texture("bright", "明亮"),
        texture("dark", "暗色"),
        texture("transparent", "通透"),
        texture("airy", "空气感"),
        texture("rich", "丰润"),
        texture("thick", "厚实"),
        texture("dense", "密集"),
        texture("sparse", "稀疏"),
        texture("minimal", "极简"),
        texture("intricate", "繁复"),
        texture("clean", "干净"),
        texture("refined", "精致"),
        texture("rough", "粗糙"),
        texture("gritty", "粗粝"),
        texture("distorted", "失真"),
        texture("grainy", "颗粒感"),
        texture("noisy", "噪音感"),
        texture("smooth", "平滑"),
        texture("silky", "丝滑"),
        texture("soft", "柔软"),
        texture("hard", "硬朗"),
        texture("sharp", "尖锐"),
        texture("dry", "干声"),
        texture("reverb_rich", "混响丰富"),
        texture("spacious", "空间宽阔"),
        texture("close", "近距离"),
        texture("immersive", "包围感"),
        texture("wide_stereo", "宽立体声"),
        texture("analog", "模拟味"),
        texture("digital", "数字感"),
        texture("retro_production", "复古制作"),
        texture("future_production", "未来制作"),
        texture("lofi", "Lo-fi"),
        texture("hifi", "Hi-fi"),
        texture("live", "现场感"),
        texture("studio", "录音室感"),
        texture("cinematic", "电影感"),
        texture("atmospheric", "氛围化"),
        texture("impactful", "冲击感"),
        texture("deep_bass", "厚重低频"),
        texture("clear_highs", "清澈高频"),
        texture("shimmering", "闪亮"),
        texture("hazy", "朦胧"),
        texture("glitch", "Glitch"),
        texture("dreamy_production", "Dreamy Production"),
        texture("wall_of_sound", "Wall of Sound"),
    ]

    private static let rhythms: [TagDefinition] = [
        rhythm("straight", "直拍"),
        rhythm("swing", "Swing"),
        rhythm("shuffle", "Shuffle"),
        rhythm("syncopated", "切分"),
        rhythm("four_on_floor", "Four-on-the-floor"),
        rhythm("breakbeat", "Breakbeat"),
        rhythm("half_time", "Half-time"),
        rhythm("double_time", "Double-time"),
        rhythm("driving", "强推进"),
        rhythm("loose_groove", "松弛律动"),
        rhythm("funk_groove", "Funk Groove"),
        rhythm("latin_groove", "Latin Groove"),
        rhythm("afro_groove", "Afro Groove"),
        rhythm("reggae_offbeat", "Reggae Offbeat"),
        rhythm("triple_meter", "三拍子"),
        rhythm("compound_meter", "复合拍"),
        rhythm("polyrhythm", "Polyrhythm"),
        rhythm("odd_meter", "Odd Meter"),
        rhythm("steady_pulse", "稳定脉冲"),
        rhythm("free_time", "自由节拍"),
        rhythm("rubato", "Rubato"),
        rhythm("march", "March"),
        rhythm("motorik", "Motorik"),
        rhythm("trap_hi_hat", "Trap Hi-hat"),
        rhythm("boom_bap_groove", "Boom Bap Groove"),
    ]
}
