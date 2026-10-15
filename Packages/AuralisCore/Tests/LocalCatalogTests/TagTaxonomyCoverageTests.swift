// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
import LocalCatalog
import Testing

@Test("Daily and professional vocabulary resolves without losing ambiguity or fixed ID compatibility")
func dailyAndProfessionalTagVocabulary() {
    let examples = [
        "自习": "scene.study", "下班路上": "scene.commute", "纯音乐": "vocal.instrumental",
        "后摇": "style.post_rock", "钢琴独奏": "style.solo_piano", "爵士说唱": "style.jazz_rap",
        "双簧管": "instrument.oboe", "哄宝宝睡觉": "scene.baby_soothing", "番茄工作法": "scene.pomodoro",
        "Ｓｙｎｔｈ－Ｐｏｐ": "style.synth_pop", "synth_pop": "style.synth_pop",
    ]
    for (phrase, id) in examples {
        #expect(RecommendationIndexTaxonomy.resolve(phrase)?.id.rawValue == id)
        #expect(RecommendationIndexTaxonomy.search(phrase).first?.id.rawValue == id)
    }
    #expect(RecommendationIndexTaxonomy.resolve("温暖") == nil)
    #expect(Set(RecommendationIndexTaxonomy.search("温暖").map(\.id.rawValue)).isSuperset(of: ["mood.warm", "texture.warm"]))
    #expect(!RecommendationIndexTaxonomy.validate().contains { $0.contains("not reversible") || $0.contains("duplicate id") })
    #expect(RecommendationIndexTaxonomy.compactClassifierCatalogByteCount < 32_000)
}
