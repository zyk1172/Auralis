// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
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

/// Result of resolving a model/user value against the fixed taxonomy.
/// Ambiguity is explicit so a caller can drop a value instead of silently
/// assigning it to an unrelated dimension.
public enum TaxonomyResolution: Equatable, Hashable, Sendable {
    case resolved(TagDefinition)
    case ambiguous([TagDefinition])
    case unknown

    public var definition: TagDefinition? {
        guard case let .resolved(definition) = self else { return nil }
        return definition
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

    public static let byID: [TagID: TagDefinition] = all.reduce(into: [:]) { result, tag in
        // Keep the first definition deterministic. `validate()` reports the
        // duplicate instead of allowing Dictionary construction to trap.
        if result[tag.id] == nil { result[tag.id] = tag }
    }

    public static let byDimension: [TagDimension: [TagDefinition]] = Dictionary(
        grouping: all,
        by: \.dimension
    )

    /// Every normalized display/alias key keeps all candidates. A single
    /// `[String: TagDefinition]` would overwrite valid cross-dimension values
    /// such as mood.warm and texture.warm.
    public static let byNormalizedDisplay: [String: [TagDefinition]] = {
        Dictionary(grouping: all, by: { normalize($0.displayName) })
            .mapValues { $0.sorted { $0.id.rawValue < $1.id.rawValue } }
    }()

    public static let byNormalizedAlias: [String: [TagDefinition]] = {
        var index: [String: [TagDefinition]] = [:]
        for tag in all {
            for alias in tag.aliases {
                index[normalize(alias), default: []].append(tag)
            }
        }
        return index.mapValues {
            $0.sorted { $0.id.rawValue < $1.id.rawValue }
        }
    }()

    /// Explicit diagnostics for values that are not globally unique. These
    /// are public so validation/tests can prove no candidate was lost by an
    /// index overwrite.
    public static let globalDisplayAmbiguities: [String: [TagID]] = ambiguousIDs(in: byNormalizedDisplay)
    public static let globalAliasAmbiguities: [String: [TagID]] = ambiguousIDs(in: byNormalizedAlias)
    public static let globalDisplayAliasCollisions: [String: [TagID]] = {
        var candidates: [String: Set<TagID>] = [:]
        for (key, definitions) in byNormalizedDisplay {
            candidates[key, default: []].formUnion(definitions.map(\.id))
        }
        for (key, definitions) in byNormalizedAlias {
            candidates[key, default: []].formUnion(definitions.map(\.id))
        }
        return candidates.compactMapValues { ids in
            guard ids.count > 1 else { return nil }
            return ids.sorted { $0.rawValue < $1.rawValue }
        }
    }()

    public static func resolve(_ raw: String) -> TagDefinition? {
        switch resolution(raw, expectedDimension: nil) {
        case let .resolved(definition): return definition
        case .ambiguous, .unknown: return nil
        }
    }

    /// Resolve within the expected dimension first. A complete canonical ID
    /// always wins and is rerouted to its owning dimension. Display names and
    /// aliases may cross dimensions only when the global candidate is unique.
    public static func resolve(
        _ raw: String,
        expectedDimension: TagDimension
    ) -> TaxonomyResolution {
        resolution(raw, expectedDimension: expectedDimension)
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
        let exact = uniqueDefinitions(for: needle)
        var ranked: [(score: Int, tag: TagDefinition)] = []
        for tag in exact {
            ranked.append((0, tag))
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
        var displaysByDimension: [TagDimension: [String: [TagID]]] = [:]
        var aliasesByDimension: [TagDimension: [String: [TagID]]] = [:]
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
            if displayKey.isEmpty { issues.append("\(tag.id.rawValue) empty display") }
            displaysByDimension[tag.dimension, default: [:]][displayKey, default: []].append(tag.id)
            for alias in tag.aliases {
                let key = normalize(alias)
                if key.isEmpty { issues.append("\(tag.id.rawValue) empty alias") }
                guard byID[tag.id] != nil else {
                    issues.append("alias \(alias) points to invalid tag \(tag.id.rawValue)")
                    continue
                }
                aliasesByDimension[tag.dimension, default: [:]][key, default: []].append(tag.id)
            }
        }

        for dimension in TagDimension.allCases {
            for (key, ids) in displaysByDimension[dimension] ?? [:] where Set(ids).count > 1 {
                issues.append("duplicate display \(key) in \(dimension.rawValue): \(ids.map(\.rawValue).sorted().joined(separator: ","))")
            }
            for (key, ids) in aliasesByDimension[dimension] ?? [:] where Set(ids).count > 1 {
                issues.append("ambiguous alias \(key) in \(dimension.rawValue): \(ids.map(\.rawValue).sorted().joined(separator: ","))")
            }
            let displayKeys = Set((displaysByDimension[dimension] ?? [:]).keys)
            for (key, aliasIDs) in aliasesByDimension[dimension] ?? [:] where displayKeys.contains(key) {
                let displayIDs = Set(displaysByDimension[dimension]?[key] ?? [])
                if displayIDs != Set(aliasIDs) {
                    issues.append("alias/display collision \(key) in \(dimension.rawValue)")
                }
            }
        }

        // Every canonical ID, display name, and alias must resolve back to
        // the definition that owns it when the expected dimension is known.
        // This catches a future index/normalization change before it can turn
        // a valid taxonomy entry into an unresolvable write value.
        for tag in all {
            if byID[tag.id]?.id != tag.id {
                issues.append("canonical id \(tag.id.rawValue) is not uniquely resolvable")
            }
            if Self.resolve(tag.displayName, expectedDimension: tag.dimension).definition?.id != tag.id {
                issues.append("display \(tag.displayName) is not reversible for \(tag.id.rawValue)")
            }
            for alias in tag.aliases
                where Self.resolve(alias, expectedDimension: tag.dimension).definition?.id != tag.id {
                issues.append("alias \(alias) is not reversible for \(tag.id.rawValue)")
            }
        }

        for (key, ids) in globalDisplayAmbiguities {
            issues.append("global display ambiguity \(key): \(ids.map(\.rawValue).joined(separator: ","))")
        }
        for (key, ids) in globalAliasAmbiguities {
            issues.append("global alias ambiguity \(key): \(ids.map(\.rawValue).joined(separator: ","))")
        }
        for (key, ids) in globalDisplayAliasCollisions {
            issues.append("global display/alias collision \(key): \(ids.map(\.rawValue).joined(separator: ","))")
        }
        return issues
    }

    /// Compact, deterministic classifier catalog for providers that cannot
    /// consume the JSON Schema enum. It intentionally contains only TagID and
    /// displayName; aliases and long documentation remain local sanitizer data.
    public static let compactClassifierCatalog: String = TagDimension.allCases.map { dimension in
        let entries = definitions(for: dimension)
            .map { "\($0.id.rawValue)=\($0.displayName)" }
            .joined(separator: "\n")
        return "\(dimension.rawValue.uppercased()):\n\(entries)"
    }.joined(separator: "\n")

    public static var compactClassifierCatalogByteCount: Int {
        compactClassifierCatalog.utf8.count
    }

    private static func ambiguousIDs(
        in index: [String: [TagDefinition]]
    ) -> [String: [TagID]] {
        index.compactMapValues { definitions in
            let ids = Set(definitions.map(\.id))
            guard ids.count > 1 else { return nil }
            return ids.sorted { $0.rawValue < $1.rawValue }
        }
    }

    private static func uniqueDefinitions(for normalized: String) -> [TagDefinition] {
        var byID: [TagID: TagDefinition] = [:]
        for definition in (byNormalizedDisplay[normalized] ?? []) + (byNormalizedAlias[normalized] ?? []) {
            byID[definition.id] = definition
        }
        return byID.values.sorted { $0.id.rawValue < $1.id.rawValue }
    }

    private static func resolution(
        _ raw: String,
        expectedDimension: TagDimension?
    ) -> TaxonomyResolution {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .unknown }
        if let canonical = byID[TagID(rawValue: trimmed)] {
            return .resolved(canonical)
        }

        let global = uniqueDefinitions(for: normalize(trimmed))
        if let expectedDimension {
            let expected = global.filter { $0.dimension == expectedDimension }
            if expected.count == 1, let definition = expected.first {
                return .resolved(definition)
            }
            if expected.count > 1 {
                return .ambiguous(expected)
            }
        }
        if global.count == 1, let definition = global.first {
            return .resolved(definition)
        }
        return global.isEmpty ? .unknown : .ambiguous(global)
    }

    private static func normalize(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
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
        mood("calm", "平静", aliases: ["安静", "calm"]),
        mood("peaceful", "宁静"),
        mood("serene", "平和"),
        mood("relaxed", "放松", aliases: ["轻松", "松弛", "松弛感", "relaxed"]),
        mood("soothing", "舒缓"),
        mood("healing", "治愈", aliases: ["治愈系", "疗愈感"]),
        mood("comforting", "安慰"),
        mood("warm", "温暖"),
        mood("soft", "柔和"),
        mood("light", "轻盈"),
        mood("fresh", "清新"),
        mood("cozy", "惬意", aliases: ["舒服", "惬意感"]),
        mood("languid", "慵懒", aliases: ["懒洋洋"]),
        mood("leisurely", "闲适"),
        mood("restrained", "克制"),
        mood("quiet", "沉静"),
        mood("bright", "明亮"),
        mood("sunny", "阳光"),
        mood("happy", "快乐", aliases: ["开心"]),
        mood("joyful", "欢乐"),
        mood("delight", "喜悦"),
        mood("excited", "兴奋"),
        mood("ecstatic", "狂喜"),
        mood("uplifting", "振奋", aliases: ["振奋人心"]),
        mood("inspiring", "鼓舞", aliases: ["鼓舞人心"]),
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
        mood("nostalgic", "怀旧", aliases: ["怀旧感"]),
        mood("melancholic", "惆怅"),
        mood("bittersweet", "苦涩"),
        mood("sad", "悲伤", aliases: ["伤感", "难过", "sad"]),
        mood("gloomy", "忧郁"),
        mood("lonely", "孤独", aliases: ["孤单"]),
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
        mood("reconciled", "释然", aliases: ["放下了"]),
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
        mood("burning", "燃", aliases: ["燃系", "热血沸腾"]),
        mood("urgent", "急迫"),
        mood("restless", "躁动"),
        mood("wild", "狂野"),
        mood("explosive", "爆发"),
        mood("cathartic", "宣泄", aliases: ["情绪宣泄"]),
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
        mood("ethereal", "空灵", aliases: ["空灵感"]),
        mood("dreamy", "梦幻", aliases: ["梦幻感"]),
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
        scene("bedtime", "睡前", aliases: ["临睡前", "入睡前"]),
        scene("waking_up", "起床", aliases: ["起床时"]),
        scene("commute", "通勤", aliases: ["上班路上", "下班路上", "上下班", "通勤路上", "commuting"]),
        scene("work", "工作", aliases: ["上班", "工作时"]),
        scene("office", "办公", aliases: ["办公室"]),
        scene("study", "学习", aliases: ["自习", "看书学习", "study"]),
        scene("focus", "专注", aliases: ["集中注意力", "专心", "focus"]),
        scene("reading", "阅读", aliases: ["读书", "reading"]),
        scene("writing", "写作"),
        scene("coding", "编程", aliases: ["写代码", "敲代码", "coding"]),
        scene("exam", "做题", aliases: ["刷题", "备考"]),
        scene("creative_work", "创作"),
        scene("drawing", "画画"),
        scene("background", "背景音乐", aliases: ["BGM", "bgm音乐", "背景声"]),
        scene("work_break", "工作休息"),
        scene("study_sprint", "学习冲刺"),
        scene("home", "居家", aliases: ["在家", "一个人在家"]),
        scene("cooking", "做饭", aliases: ["下厨", "做菜"]),
        scene("dining", "吃饭"),
        scene("breakfast", "早餐"),
        scene("lunch", "午餐"),
        scene("dinner", "晚餐"),
        scene("cleaning", "清洁", aliases: ["打扫卫生"]),
        scene("housework", "家务", aliases: ["做家务"]),
        scene("organizing", "整理房间"),
        scene("shower", "洗澡", aliases: ["冲澡"]),
        scene("bath", "泡澡"),
        scene("daydreaming", "发呆", aliases: ["走神", "放空发呆"]),
        scene("nap", "午休", aliases: ["午睡"]),
        scene("siesta", "小憩"),
        scene("meditation", "冥想", aliases: ["打坐"]),
        scene("yoga", "瑜伽"),
        scene("stretching", "拉伸"),
        scene("sleeping", "睡眠", aliases: ["睡觉", "sleep"]),
        scene("getting_ready", "起床准备"),
        scene("walking", "散步", aliases: ["遛弯", "散散步"]),
        scene("city_walk", "城市漫步", aliases: ["citywalk", "city walk", "逛街漫步"]),
        scene("park", "公园"),
        scene("hiking", "徒步"),
        scene("mountaineering", "登山"),
        scene("camping", "露营"),
        scene("seaside", "海边", aliases: ["海滩"]),
        scene("wilderness", "山野"),
        scene("outdoor", "户外"),
        scene("sunset_viewing", "看日落"),
        scene("stargazing", "看星空", aliases: ["观星"]),
        scene("running", "跑步", aliases: ["慢跑", "跑步时", "running"]),
        scene("night_running", "夜跑", aliases: ["晚上跑步"]),
        scene("fitness", "健身", aliases: ["撸铁健身", "gym"]),
        scene("strength_training", "力量训练", aliases: ["撸铁", "力量练习", "举铁"]),
        scene("cardio", "有氧运动", aliases: ["有氧训练"]),
        scene("cycling", "骑行", aliases: ["骑自行车"]),
        scene("warmup", "热身"),
        scene("sprint", "运动冲刺"),
        scene("recovery", "运动恢复"),
        scene("driving", "驾车", aliases: ["开车", "自驾"]),
        scene("night_driving", "夜间驾车", aliases: ["开夜车", "夜间开车", "深夜开车", "深夜驾车"]),
        scene("long_drive", "长途驾车"),
        scene("road_trip", "公路旅行", aliases: ["自驾旅行"]),
        scene("subway", "地铁"),
        scene("bus", "公交"),
        scene("train", "火车"),
        scene("high_speed_rail", "高铁"),
        scene("flight", "飞行"),
        scene("waiting", "候机"),
        scene("travel", "旅行", aliases: ["旅途", "旅游"]),
        scene("friends_gathering", "朋友小聚", aliases: ["朋友聚餐"]),
        scene("family_gathering", "家庭聚会"),
        scene("party", "聚会"),
        scene("club", "派对"),
        scene("nightclub", "夜店"),
        scene("bar", "酒吧"),
        scene("cafe", "咖啡馆", aliases: ["咖啡店"]),
        scene("afternoon_tea", "下午茶"),
        scene("date", "约会", aliases: ["约会时"]),
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
        scene("spring", "春日", aliases: ["春天"]),
        scene("summer", "夏日", aliases: ["夏天"]),
        scene("autumn", "秋日", aliases: ["秋天"]),
        scene("winter", "冬日", aliases: ["冬天"]),
        scene("bedroom", "卧室"),
        scene("living_room", "客厅"),
        scene("library", "图书馆", aliases: ["图书馆自习"]),
        scene("city_night", "城市夜景"),
        scene("pomodoro", "番茄钟", aliases: ["番茄工作法", "pomodoro"]),
        scene("deep_work", "深度工作", aliases: ["沉浸工作", "deep work"]),
        scene("after_work", "下班放松", aliases: ["下班后", "收工后"]),
        scene("stress_relief", "解压", aliases: ["释放压力", "减压放松"]),
        scene("weekend", "周末", aliases: ["周末时光"]),
        scene("gaming", "游戏时", aliases: ["打游戏", "玩游戏"]),
        scene("board_games", "桌游", aliases: ["桌游聚会"]),
        scene("handcraft", "手作", aliases: ["做手工", "手工制作"]),
        scene("journaling", "写日记", aliases: ["日记时间"]),
        scene("gardening", "园艺", aliases: ["养花"]),
        scene("balcony", "阳台", aliases: ["阳台休息"]),
        scene("morning_coffee", "晨间咖啡", aliases: ["早上喝咖啡"]),
        scene("late_night_snack", "夜宵", aliases: ["吃夜宵"]),
        scene("solo_dining", "一人食", aliases: ["一个人吃饭"]),
        scene("pet_time", "陪伴宠物", aliases: ["和宠物玩"]),
        scene("parent_child", "亲子时光", aliases: ["亲子陪伴"]),
        scene("baby_soothing", "哄睡", aliases: ["哄宝宝睡觉"]),
        scene("skateboarding", "滑板", aliases: ["玩滑板"]),
        scene("swimming", "游泳", aliases: ["泳池运动"]),
        scene("pilates", "普拉提", aliases: ["pilates"]),
        scene("dance_practice", "舞蹈练习", aliases: ["练舞"]),
        scene("karaoke", "K歌", aliases: ["卡拉OK", "唱K"]),
        scene("barbecue", "烧烤", aliases: ["户外烧烤"]),
        scene("picnic", "野餐", aliases: ["草地野餐"]),
        scene("homesick", "想家时", aliases: ["想家的时候"]),
        scene("emotional_recovery", "情绪低谷陪伴", aliases: ["低谷时", "难熬的时候"]),
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
        theme("breakup", "失恋", aliases: ["失恋主题"]),
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
        theme("alertness", "清醒提神", aliases: ["提神", "醒脑"]),
        theme("sleep_aid", "助眠", aliases: ["帮助入睡"]),
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
        genre("pop", "流行", aliases: ["流行音乐", "Pop"]),
        genre("rock", "摇滚", aliases: ["摇滚乐", "Rock"]),
        genre("electronic", "电子音乐", aliases: ["电子", "电子乐", "电音", "Electronic"]),
        genre("hip_hop", "嘻哈", aliases: ["hiphop", "hip-hop", "说唱", "嘻哈音乐", "Hip Hop", "Hip-Hop"]),
        genre("r_and_b_soul", "R&B / Soul", aliases: ["节奏布鲁斯与灵魂乐"]),
        genre("jazz", "爵士", aliases: ["爵士乐", "Jazz"]),
        genre("classical", "古典音乐", aliases: ["古典", "古典乐", "Classical"]),
        genre("folk", "民谣 / Singer-Songwriter", aliases: ["民谣", "民谣音乐"]),
        genre("metal", "金属", aliases: ["金属乐", "Metal"]),
        genre("punk", "朋克"),
        genre("blues", "蓝调", aliases: ["布鲁斯", "Blues"]),
        genre("country", "乡村"),
        genre("funk", "放克"),
        genre("disco", "迪斯科 / 舞曲", aliases: ["舞曲"]),
        genre("reggae", "雷鬼 / Jamaican", aliases: ["雷鬼"]),
        genre("latin", "拉丁"),
        genre("world", "世界音乐"),
        genre("traditional", "传统 / 民族音乐", aliases: ["传统民族音乐"]),
        genre("ambient", "Ambient / New Age", aliases: ["氛围与新世纪音乐"]),
        genre("soundtrack", "Soundtrack / 配乐", aliases: ["原声带", "配乐", "影视配乐"]),
        genre("experimental", "实验 / 先锋"),
        genre("gospel", "宗教 / Gospel"),
        genre("children", "儿童音乐"),
        genre("comedy", "喜剧 / Novelty"),
        genre("musical", "音乐剧"),
        genre("chinese_opera", "戏曲 / 曲艺", aliases: ["戏曲曲艺"]),
    ]

    private static let styles: [TagDefinition] = [
        style("dance_pop", "Dance Pop", aliases: ["舞曲流行"]),
        style("synth_pop", "Synth-pop", aliases: ["合成器流行", "Synth Pop"]),
        style("electropop", "Electropop"),
        style("indie_pop", "Indie Pop", aliases: ["独立流行"]),
        style("art_pop", "Art Pop", aliases: ["艺术流行"]),
        style("dream_pop", "Dream Pop", aliases: ["梦幻流行"]),
        style("chamber_pop", "Chamber Pop"),
        style("baroque_pop", "Baroque Pop"),
        style("power_pop", "Power Pop"),
        style("pop_rock", "Pop Rock"),
        style("teen_pop", "Teen Pop"),
        style("adult_contemporary", "Adult Contemporary"),
        style("sophisti_pop", "Sophisti-pop"),
        style("city_pop", "City Pop", aliases: ["城市流行", "都市流行"]),
        style("j_pop", "J-Pop", aliases: ["日系流行", "日本流行"]),
        style("k_pop", "K-Pop", aliases: ["韩国流行", "韩流音乐"]),
        style("c_pop", "C-Pop", aliases: ["中国流行"]),
        style("mandopop", "Mandopop", aliases: ["华语流行", "国语流行"]),
        style("cantopop", "Cantopop", aliases: ["粤语流行", "粤语流行乐"]),
        style("sunshine_pop", "Sunshine Pop"),
        style("psychedelic_pop", "Psychedelic Pop"),
        style("hyperpop", "Hyperpop"),
        style("bedroom_pop", "Bedroom Pop", aliases: ["卧室流行"]),
        style("bubblegum_pop", "Bubblegum Pop"),
        style("folk_pop", "Folk Pop"),
        style("pop_rap", "Pop Rap"),
        style("alternative_pop", "Alternative Pop"),
        style("indietronica", "Indietronica"),
        style("classic_rock", "Classic Rock", aliases: ["经典摇滚"]),
        style("alternative_rock", "Alternative Rock", aliases: ["另类摇滚"]),
        style("indie_rock", "Indie Rock", aliases: ["独立摇滚"]),
        style("art_rock", "Art Rock"),
        style("progressive_rock", "Progressive Rock", aliases: ["前卫摇滚"]),
        style("psychedelic_rock", "Psychedelic Rock", aliases: ["迷幻摇滚"]),
        style("hard_rock", "Hard Rock", aliases: ["硬摇滚"]),
        style("soft_rock", "Soft Rock"),
        style("arena_rock", "Arena Rock"),
        style("garage_rock", "Garage Rock"),
        style("glam_rock", "Glam Rock"),
        style("blues_rock", "Blues Rock"),
        style("folk_rock", "Folk Rock"),
        style("country_rock", "Country Rock"),
        style("southern_rock", "Southern Rock"),
        style("surf_rock", "Surf Rock"),
        style("post_rock", "Post-Rock", aliases: ["后摇", "后摇滚"]),
        style("math_rock", "Math Rock", aliases: ["数学摇滚"]),
        style("noise_rock", "Noise Rock"),
        style("shoegaze", "Shoegaze", aliases: ["盯鞋", "自赏摇滚"]),
        style("grunge", "Grunge", aliases: ["垃圾摇滚"]),
        style("britpop", "Britpop", aliases: ["英伦摇滚"]),
        style("gothic_rock", "Gothic Rock"),
        style("stoner_rock", "Stoner Rock"),
        style("krautrock", "Krautrock"),
        style("rockabilly", "Rockabilly"),
        style("experimental_rock", "Experimental Rock"),
        style("space_rock", "Space Rock"),
        style("post_grunge", "Post-Grunge"),
        style("punk_rock", "Punk Rock", aliases: ["朋克摇滚"]),
        style("pop_punk", "Pop Punk"),
        style("post_punk", "Post-Punk", aliases: ["后朋克"]),
        style("hardcore_punk", "Hardcore Punk"),
        style("post_hardcore", "Post-Hardcore"),
        style("emo", "Emo"),
        style("screamo", "Screamo"),
        style("skate_punk", "Skate Punk"),
        style("garage_punk", "Garage Punk"),
        style("crust_punk", "Crust Punk"),
        style("anarcho_punk", "Anarcho-Punk"),
        style("oi", "Oi!"),
        style("new_wave", "New Wave", aliases: ["新浪潮"]),
        style("no_wave", "No Wave"),
        style("heavy_metal", "Heavy Metal", aliases: ["重金属"]),
        style("thrash_metal", "Thrash Metal"),
        style("death_metal", "Death Metal", aliases: ["死亡金属"]),
        style("melodic_death_metal", "Melodic Death Metal"),
        style("black_metal", "Black Metal", aliases: ["黑金属"]),
        style("doom_metal", "Doom Metal"),
        style("sludge_metal", "Sludge Metal"),
        style("stoner_metal", "Stoner Metal"),
        style("power_metal", "Power Metal"),
        style("symphonic_metal", "Symphonic Metal", aliases: ["交响金属"]),
        style("progressive_metal", "Progressive Metal", aliases: ["前卫金属"]),
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
        style("house", "House", aliases: ["浩室"]),
        style("deep_house", "Deep House", aliases: ["深浩室"]),
        style("tech_house", "Tech House"),
        style("progressive_house", "Progressive House"),
        style("electro_house", "Electro House"),
        style("future_house", "Future House"),
        style("tropical_house", "Tropical House"),
        style("acid_house", "Acid House"),
        style("techno", "Techno", aliases: ["铁克诺"]),
        style("minimal_techno", "Minimal Techno"),
        style("detroit_techno", "Detroit Techno"),
        style("industrial_techno", "Industrial Techno"),
        style("trance", "Trance", aliases: ["出神舞曲"]),
        style("progressive_trance", "Progressive Trance"),
        style("psytrance", "Psytrance"),
        style("uplifting_trance", "Uplifting Trance"),
        style("drum_and_bass", "Drum & Bass", aliases: ["鼓与贝斯", "DnB", "Drum and Bass"]),
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
        style("downtempo", "Downtempo", aliases: ["缓拍"]),
        style("chillout", "Chillout", aliases: ["驰放"]),
        style("trip_hop", "Trip-Hop", aliases: ["神游舞曲"]),
        style("idm", "IDM"),
        style("glitch", "Glitch"),
        style("vaporwave", "Vaporwave", aliases: ["蒸汽波"]),
        style("synthwave", "Synthwave", aliases: ["合成波"]),
        style("retrowave", "Retrowave"),
        style("chillwave", "Chillwave", aliases: ["寒潮音乐"]),
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
        style("cloud_rap", "Cloud Rap", aliases: ["云说唱"]),
        style("conscious_hip_hop", "Conscious Hip-Hop"),
        style("alternative_hip_hop", "Alternative Hip-Hop"),
        style("experimental_hip_hop", "Experimental Hip-Hop"),
        style("jazz_rap", "Jazz Rap", aliases: ["爵士说唱"]),
        style("lofi_hip_hop", "Lo-fi Hip-Hop", aliases: ["低保真嘻哈", "Lo fi Hip Hop"]),
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
        style("neo_soul", "Neo Soul", aliases: ["新灵魂乐"]),
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
        style("big_band", "Big Band", aliases: ["大乐队爵士"]),
        style("bebop", "Bebop", aliases: ["比博普"]),
        style("hard_bop", "Hard Bop"),
        style("cool_jazz", "Cool Jazz", aliases: ["冷爵士"]),
        style("modal_jazz", "Modal Jazz", aliases: ["调式爵士"]),
        style("free_jazz", "Free Jazz"),
        style("jazz_fusion", "Jazz Fusion", aliases: ["融合爵士"]),
        style("smooth_jazz", "Smooth Jazz", aliases: ["柔顺爵士"]),
        style("latin_jazz", "Latin Jazz", aliases: ["拉丁爵士"]),
        style("afro_cuban_jazz", "Afro-Cuban Jazz"),
        style("vocal_jazz", "Vocal Jazz", aliases: ["人声爵士"]),
        style("gypsy_jazz", "Gypsy Jazz"),
        style("nu_jazz", "Nu Jazz"),
        style("acid_jazz", "Acid Jazz"),
        style("jazz_funk", "Jazz-Funk"),
        style("baroque", "Baroque", aliases: ["巴洛克"]),
        style("classical_period", "Classical Period", aliases: ["古典主义"]),
        style("romantic", "Romantic", aliases: ["浪漫主义"]),
        style("modern_classical", "Modern Classical"),
        style("contemporary_classical", "Contemporary Classical"),
        style("minimalism", "Minimalism", aliases: ["极简主义"]),
        style("impressionism", "Impressionism", aliases: ["印象主义"]),
        style("chamber_music", "Chamber Music", aliases: ["室内乐"]),
        style("orchestral", "Orchestral", aliases: ["管弦乐"]),
        style("symphony", "Symphony", aliases: ["交响曲"]),
        style("concerto", "Concerto", aliases: ["协奏曲"]),
        style("sonata", "Sonata", aliases: ["奏鸣曲"]),
        style("opera", "Opera", aliases: ["歌剧"]),
        style("choral", "Choral"),
        style("sacred_classical", "Sacred Classical"),
        style("solo_piano", "Solo Piano", aliases: ["钢琴独奏"]),
        style("string_quartet", "String Quartet", aliases: ["弦乐四重奏"]),
        style("ballet", "Ballet"),
        style("neoclassical", "Neoclassical", aliases: ["新古典"]),
        style("classical_crossover", "Classical Crossover"),
        style("traditional_folk", "Traditional Folk"),
        style("contemporary_folk", "Contemporary Folk"),
        style("indie_folk", "Indie Folk", aliases: ["独立民谣"]),
        style("singer_songwriter", "Singer-Songwriter", aliases: ["创作歌手风格"]),
        style("americana", "Americana"),
        style("bluegrass", "Bluegrass", aliases: ["蓝草"]),
        style("celtic", "Celtic", aliases: ["凯尔特音乐"]),
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
        style("bossa_nova", "Bossa Nova", aliases: ["波萨诺瓦", "巴萨诺瓦"]),
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
        style("chinese_traditional", "Chinese Traditional", aliases: ["中国传统音乐"]),
        style("guofeng", "国风"),
        style("gufeng", "古风"),
        style("minyue", "民乐"),
        style("xiqu", "戏曲"),
        style("mongolian", "蒙古音乐"),
        style("tibetan", "藏族音乐"),
        style("xinjiang", "新疆民族音乐"),
        style("film_score", "Film Score", aliases: ["电影配乐"]),
        style("tv_score", "TV Score", aliases: ["电视剧配乐"]),
        style("game_soundtrack", "Game Soundtrack", aliases: ["游戏原声", "游戏配乐"]),
        style("anime_soundtrack", "Anime Soundtrack", aliases: ["动漫原声", "动画配乐"]),
        style("musical_theatre", "Musical Theatre", aliases: ["音乐剧风格"]),
        style("cinematic", "Cinematic"),
        style("trailer_music", "Trailer Music"),
        style("library_music", "Library Music"),
        style("new_age", "New Age", aliases: ["新世纪音乐"]),
        style("meditation_music", "Meditation Music", aliases: ["冥想音乐"]),
        style("easy_listening", "Easy Listening", aliases: ["轻音乐", "轻松聆听"]),
        style("lounge", "Lounge", aliases: ["沙发音乐"]),
        style("exotica", "Exotica"),
        style("christmas", "Christmas", aliases: ["圣诞音乐"]),
        style("childrens_music", "Children's Music", aliases: ["儿歌"]),
        style("comedy_music", "Comedy Music"),
        style("spoken_word", "Spoken Word"),
        style("experimental", "Experimental"),
        style("avant_garde", "Avant-Garde"),
        style("sound_art", "Sound Art"),
        style("ambient_pop", "氛围流行", aliases: ["Ambient Pop"]),
        style("jazzhop", "爵士嘻哈器乐", aliases: ["Jazzhop"]),
        style("chillhop", "Chillhop", aliases: ["驰放嘻哈"]),
        style("lofi_house", "Lo-fi House", aliases: ["低保真浩室"]),
        style("organic_house", "Organic House", aliases: ["有机浩室"]),
        style("amapiano", "Amapiano", aliases: ["南非钢琴浩室"]),
        style("uk_drill", "UK Drill", aliases: ["英国钻头说唱"]),
        style("rage_rap", "Rage Rap", aliases: ["狂暴说唱"]),
        style("chinese_rock", "中国摇滚", aliases: ["Chinese Rock"]),
        style("chinese_folk", "中国民谣", aliases: ["Chinese Folk"]),
    ]

    private static let vocals: [TagDefinition] = [
        vocal("instrumental", "器乐 / 无人声", aliases: ["纯音乐", "无人声", "没有歌词", "无歌词", "纯器乐", "没有人声", "无人唱"]),
        vocal("male_lead", "男主唱", aliases: ["男声", "男歌手", "男歌手主唱"]),
        vocal("female_lead", "女主唱", aliases: ["女声", "女歌手", "女歌手主唱"]),
        vocal("mixed_lead", "男女混合主唱"),
        vocal("duet", "对唱", aliases: ["双人对唱"]),
        vocal("ensemble", "多人合唱"),
        vocal("choir", "合唱团", aliases: ["合唱", "唱诗班", "人声合唱团"]),
        vocal("children", "童声"),
        vocal("group_vocal", "群体人声"),
        vocal("harmony_prominent", "和声突出", aliases: ["和声丰富"]),
        vocal("rap", "说唱", aliases: ["Rap"]),
        vocal("half_sung_half_rap", "半说半唱"),
        vocal("spoken_word", "念白"),
        vocal("recitation", "朗诵"),
        vocal("chant", "吟唱"),
        vocal("a_cappella", "清唱", aliases: ["阿卡贝拉", "无伴奏人声"]),
        vocal("whisper", "低语", aliases: ["耳语唱法"]),
        vocal("breathy", "气声", aliases: ["气声唱法"]),
        vocal("falsetto", "假声", aliases: ["假声唱法"]),
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
        vocal("humming", "哼唱", aliases: ["无词哼唱"]),
        vocal("call_and_response", "Call and Response"),
    ]

    private static let instruments: [TagDefinition] = [
        instrument("piano", "钢琴", aliases: ["Piano"]),
        instrument("electric_piano", "电钢琴", aliases: ["Electric Piano"]),
        instrument("synthesizer", "合成器", aliases: ["Synthesizer"]),
        instrument("organ", "管风琴"),
        instrument("acoustic_guitar", "木吉他", aliases: ["原声吉他", "民谣吉他", "Acoustic Guitar"]),
        instrument("electric_guitar", "电吉他"),
        instrument("distorted_guitar", "失真吉他"),
        instrument("bass", "贝斯"),
        instrument("upright_bass", "低音提琴", aliases: ["倍大提琴"]),
        instrument("drums", "架子鼓"),
        instrument("drum_machine", "鼓机"),
        instrument("percussion", "打击乐"),
        instrument("eight_oh_eight", "808", aliases: ["808鼓"]),
        instrument("violin", "小提琴"),
        instrument("cello", "大提琴", aliases: ["Cello"]),
        instrument("strings", "弦乐组"),
        instrument("orchestra", "管弦乐团"),
        instrument("trumpet", "小号"),
        instrument("trombone", "长号"),
        instrument("french_horn", "圆号"),
        instrument("brass", "铜管组"),
        instrument("saxophone", "萨克斯", aliases: ["萨克斯风", "Sax"]),
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
        instrument("field_recording", "环境采样", aliases: ["实地录音采样"]),
        instrument("bells", "钟声 / Chime"),
        instrument("marimba", "木琴 / 马林巴"),
        instrument("oboe", "双簧管", aliases: ["Oboe"]),
        instrument("bassoon", "巴松管", aliases: ["大管", "Bassoon"]),
        instrument("viola", "中提琴", aliases: ["Viola"]),
        instrument("sheng", "笙", aliases: ["Sheng"]),
        instrument("ocarina", "陶笛", aliases: ["Ocarina"]),
        instrument("kalimba", "卡林巴", aliases: ["拇指琴", "Kalimba"]),
        instrument("handpan", "手碟", aliases: ["Handpan"]),
        instrument("vibraphone", "颤音琴", aliases: ["Vibraphone"]),
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
        texture("dry", "干声", aliases: ["干燥人声制作"]),
        texture("reverb_rich", "混响丰富", aliases: ["混响感"]),
        texture("spacious", "空间宽阔"),
        texture("close", "近距离"),
        texture("immersive", "包围感"),
        texture("wide_stereo", "宽立体声"),
        texture("analog", "模拟味", aliases: ["模拟质感"]),
        texture("digital", "数字感"),
        texture("retro_production", "复古制作"),
        texture("future_production", "未来制作"),
        texture("lofi", "Lo-fi", aliases: ["低保真", "Lo fi"]),
        texture("hifi", "Hi-fi", aliases: ["高保真", "Hi fi"]),
        texture("live", "现场感"),
        texture("studio", "录音室感"),
        texture("cinematic", "电影感"),
        texture("atmospheric", "氛围化", aliases: ["氛围感制作"]),
        texture("impactful", "冲击感"),
        texture("deep_bass", "厚重低频", aliases: ["低频厚重", "重低音质感"]),
        texture("clear_highs", "清澈高频"),
        texture("shimmering", "闪亮"),
        texture("hazy", "朦胧"),
        texture("glitch", "Glitch"),
        texture("dreamy_production", "Dreamy Production"),
        texture("wall_of_sound", "Wall of Sound", aliases: ["音墙"]),
    ]

    private static let rhythms: [TagDefinition] = [
        rhythm("straight", "直拍"),
        rhythm("swing", "Swing", aliases: ["摇摆节奏"]),
        rhythm("shuffle", "Shuffle", aliases: ["曳步节奏"]),
        rhythm("syncopated", "切分", aliases: ["切分节奏"]),
        rhythm("four_on_floor", "Four-on-the-floor", aliases: ["四踩", "四拍踩地"]),
        rhythm("breakbeat", "Breakbeat"),
        rhythm("half_time", "Half-time", aliases: ["半拍律动"]),
        rhythm("double_time", "Double-time", aliases: ["双倍拍律动"]),
        rhythm("driving", "强推进", aliases: ["推进感节奏"]),
        rhythm("loose_groove", "松弛律动", aliases: ["松弛节奏"]),
        rhythm("funk_groove", "Funk Groove"),
        rhythm("latin_groove", "Latin Groove"),
        rhythm("afro_groove", "Afro Groove"),
        rhythm("reggae_offbeat", "Reggae Offbeat"),
        rhythm("triple_meter", "三拍子"),
        rhythm("compound_meter", "复合拍"),
        rhythm("polyrhythm", "Polyrhythm", aliases: ["复节奏"]),
        rhythm("odd_meter", "Odd Meter", aliases: ["奇数拍"]),
        rhythm("steady_pulse", "稳定脉冲", aliases: ["稳定节拍"]),
        rhythm("free_time", "自由节拍", aliases: ["散拍"]),
        rhythm("rubato", "Rubato", aliases: ["自由速度"]),
        rhythm("march", "March"),
        rhythm("motorik", "Motorik"),
        rhythm("trap_hi_hat", "Trap Hi-hat"),
        rhythm("boom_bap_groove", "Boom Bap Groove"),
        rhythm("bossa_nova_groove", "波萨诺瓦律动", aliases: ["Bossa Nova Groove"]),
        rhythm("clave", "Clave节奏型", aliases: ["克拉维节奏"]),
        rhythm("dembow", "Dembow节奏", aliases: ["登博节奏"]),
        rhythm("waltz", "华尔兹律动", aliases: ["圆舞曲节奏"]),
    ]
}
