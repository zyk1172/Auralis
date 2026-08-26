import AgentKit
import Foundation
import LocalCatalog
import Testing

struct RecommendationIndexClassificationContractTests {
    private func batch(_ ids: [String]) -> RecommendationIndexPreparedBatch {
        let tracks = ids.map { id in
            CatalogTrackLine(
                id: id,
                title: id,
                artist: "Artist",
                album: "Album",
                year: nil,
                genres: [],
                language: nil,
                duration: 180,
                isFavorite: false,
                rating: nil,
                playCount: 0,
                isDownloaded: false
            )
        }
        return RecommendationIndexPreparedBatch(
            batchID: UUID(),
            revision: 7,
            checkpointGeneration: 1,
            mode: "full",
            tracks: tracks,
            pendingFixed: tracks.count,
            pendingSemantic: tracks.count
        )
    }

    private func envelopeJSON(
        _ id: String,
        moods: String,
        scenes: String,
        vocals: String,
        textures: String,
        styles: String,
        themes: String = "[]",
        genres: String = "[]",
        instruments: String = "[]",
        rhythms: String = "[]"
    ) -> String {
        """
        {"id":"\(id)","moods":\(moods),"scenes":\(scenes),"energy":3,"tempo":3,
         "acousticness":3,"danceability":3,"vocals":\(vocals),"textures":\(textures),
         "styles":\(styles),"themes":\(themes),"genres":\(genres),
         "instruments":\(instruments),"rhythms":\(rhythms),
         "semanticTags":[{"value":"夜行感","confidence":0.8}],
         "mode":"full","confidence":0.9}
        """
    }

    @Test("Scalar taxonomy values decode as single-element string arrays")
    func scalarTaxonomyValuesAreCompatible() throws {
        let current = batch(["track"])
        let item = envelopeJSON(
            "track",
            moods: #""mood.nostalgic""#,
            scenes: #""scene.late_night""#,
            vocals: #""vocal.female_lead""#,
            textures: #""texture.spacious""#,
            styles: #""style.city_pop""#
        )
        let json = #"{"batchID":"\#(current.batchID.uuidString)","revision":7,"mode":"full","items":[\#(item)]}"#
        let result = RecommendationIndexClassificationParser.parse(json, for: current)
        let value = try result.get()
        #expect(value.items[0].moods == ["mood.nostalgic"])
        #expect(value.items[0].scenes == ["scene.late_night"])
        #expect(value.items[0].vocals == ["vocal.female_lead"])
        #expect(value.items[0].textures == ["texture.spacious"])
        #expect(value.items[0].styles == ["style.city_pop"])
    }

    @Test("Object taxonomy values remain a codable contract failure")
    func objectTaxonomyValueIsRejected() throws {
        let current = batch(["track"])
        let json = #"{"batchID":"\#(current.batchID.uuidString)","revision":7,"mode":"full","items":[\#(envelopeJSON("track", moods:"[]", scenes:"[]", vocals:"{}", textures:"[]", styles:"[]"))]}"#
        let result = RecommendationIndexClassificationParser.parse(json, for: current)

        guard case let .failure(diagnostic) = result else {
            Issue.record("expected codableDecode failure")
            return
        }
        #expect(diagnostic.stage == .codableDecode)
        #expect(diagnostic.fieldPath == "items[0].vocals")
        #expect(diagnostic.expectedType == "string[]")
        #expect(diagnostic.actualType == "object")
        #expect(diagnostic.compactSummary.contains("field=items[0].vocals"))
        #expect(diagnostic.compactSummary.contains("expected=string[]"))
        #expect(diagnostic.compactSummary.contains("actual=object"))
    }

    @Test("semanticTags remains strict and rejects scalar compatibility")
    func semanticTagsRemainStrict() throws {
        let current = batch(["track"])
        let json = """
        {"batchID":"\(current.batchID.uuidString)","revision":7,"mode":"full",
         "items":[{"id":"track","moods":["忧郁"],"scenes":["深夜"],"energy":3,
          "tempo":3,"acousticness":3,"danceability":3,"vocals":["女声"],
          "textures":["钢琴"],"styles":["流行"],"themes":[],"genres":[],
          "instruments":[],"rhythms":[],
          "semanticTags":"怀旧","mode":"full","confidence":0.9}]}
        """
        let result = RecommendationIndexClassificationParser.parse(json, for: current)
        guard case let .failure(diagnostic) = result else {
            Issue.record("expected codableDecode failure")
            return
        }
        #expect(diagnostic.stage == .codableDecode)
        #expect(diagnostic.fieldPath?.hasSuffix("semanticTags") == true)
        #expect(diagnostic.expectedType == "object[]")
        #expect(diagnostic.actualType == "string")
    }

    @Test("Legacy diagnostics JSON decodes structured shape fields as not tested defaults")
    func legacyDiagnosticsDecode() throws {
        let old = """
        {"stage":"codableDecode","batchSize":1,"rawLength":8,"jsonFound":true,
         "message":"字段类型不匹配"}
        """
        let diagnostic = try JSONDecoder().decode(
            RecommendationIndexClassificationDiagnostics.self,
            from: Data(old.utf8)
        )
        #expect(diagnostic.fieldPath == nil)
        #expect(diagnostic.expectedType == nil)
        #expect(diagnostic.actualType == nil)
    }

    // MARK: - Taxonomy pre-validation

    @Test("Canonical taxonomy values pass parser validation")
    func canonicalTaxonomyPasses() throws {
        let current = batch(["track"])
        let item = envelopeJSON("track", moods: #"["忧郁"]"#, scenes: #"["深夜"]"#, vocals: #"["女声"]"#, textures: #"["氛围"]"#, styles: #"["流行"]"#)
        let json = #"{"batchID":"\#(current.batchID.uuidString)","revision":7,"mode":"full","items":[\#(item)]}"#
        let result = RecommendationIndexClassificationParser.parse(json, for: current)
        #expect(try result.get().items.count == 1)
    }

    @Test("Unknown values are dropped and cross-dimension tags are rerouted")
    func unknownAndCrossDimensionValuesAreSanitized() throws {
        let current = batch(["track"])
        let item = envelopeJSON(
            "track",
            moods: #"["instrument.piano","仙气飘飘神曲感"]"#,
            scenes: #"["深夜"]"#,
            vocals: #"["女声"]"#,
            textures: #"[]"#,
            styles: #"[]"#
        )
        let json = #"{"batchID":"\#(current.batchID.uuidString)","revision":7,"mode":"full","items":[\#(item)]}"#
        let result = RecommendationIndexClassificationParser.parse(json, for: current)
        let value = try result.get()
        #expect(value.items[0].moods.isEmpty)
        #expect(value.items[0].instruments.contains("instrument.piano"))
    }

    @Test("Synonym values canonicalize through taxonomy aliases")
    func synonymTaxonomyCanonicalizes() throws {
        let current = batch(["track"])
        let item = envelopeJSON("track", moods: #"["伤感"]"#, scenes: #"["夜晚"]"#, vocals: #"["女声"]"#, textures: #"["柔和"]"#, styles: #"["流行音乐"]"#)
        let json = #"{"batchID":"\#(current.batchID.uuidString)","revision":7,"mode":"full","items":[\#(item)]}"#
        let result = RecommendationIndexClassificationParser.parse(json, for: current)
        let value = try result.get()
        #expect(value.items[0].moods.contains("mood.sad"))
        #expect(value.items[0].scenes.contains("scene.night"))
        #expect(value.items[0].vocals.contains("vocal.female_lead"))
    }

    @Test("Mixed canonical and synonym values are accepted and canonicalized")
    func mixedTaxonomyIsAccepted() throws {
        let current = batch(["track"])
        let item = envelopeJSON("track", moods: #"["忧郁","伤感"]"#, scenes: #"["深夜"]"#, vocals: #"["女声"]"#, textures: #"[]"#, styles: #"[]"#)
        let json = #"{"batchID":"\#(current.batchID.uuidString)","revision":7,"mode":"full","items":[\#(item)]}"#
        let result = RecommendationIndexClassificationParser.parse(json, for: current)
        let value = try result.get()
        #expect(value.items[0].moods.contains("mood.gloomy"))
        #expect(value.items[0].moods.contains("mood.sad"))
    }

    @Test("Vocals-only categorical classification is valid")
    func vocalsOnlyIsValid() throws {
        let current = batch(["track"])
        let item = envelopeJSON("track", moods: "[]", scenes: "[]", vocals: #"["器乐"]"#, textures: "[]", styles: "[]")
        let json = #"{"batchID":"\#(current.batchID.uuidString)","revision":7,"mode":"full","items":[\#(item)]}"#
        let result = RecommendationIndexClassificationParser.parse(json, for: current)
        #expect(try result.get().items.count == 1)
    }

    @Test("Empty categorical arrays are valid when numeric dimensions pass")
    func emptyCategoricalArraysAreValid() throws {
        let current = batch(["track"])
        let item = envelopeJSON("track", moods: "[]", scenes: "[]", vocals: "[]", textures: "[]", styles: "[]")
        let json = #"{"batchID":"\#(current.batchID.uuidString)","revision":7,"mode":"full","items":[\#(item)]}"#
        let result = RecommendationIndexClassificationParser.parse(json, for: current)
        #expect(try result.get().items.count == 1)
    }

    @Test("semanticTags as plain string array fails at codableDecode stage")
    func semanticTagsStringArrayFailsCodable() throws {
        let current = batch(["track"])
        let json = """
        {"batchID":"\(current.batchID.uuidString)","revision":7,"mode":"full","items":[
          {"id":"track","moods":["忧郁"],"scenes":["深夜"],"energy":3,"tempo":3,
           "acousticness":3,"danceability":3,"vocals":["女声"],"textures":["钢琴"],
           "styles":["流行"],"themes":[],"genres":[],"instruments":[],"rhythms":[],
           "semanticTags":["夜行感"],"mode":"full","confidence":0.9}
        ]}
        """
        let result = RecommendationIndexClassificationParser.parse(json, for: current)
        guard case let .failure(diagnostic) = result else {
            Issue.record("expected codableDecode failure")
            return
        }
        #expect(diagnostic.stage == .codableDecode)
    }

    @Test("Full classification rejects missing fixed fields before Codable defaults")
    func fullClassificationMissingFieldsFailCodable() throws {
        let current = batch(["track"])
        let json = #"{"batchID":"\#(current.batchID.uuidString)","revision":7,"mode":"full","items":[{"id":"track","mode":"full"}]}"#
        let result = RecommendationIndexClassificationParser.parse(json, for: current)
        guard case let .failure(diagnostic) = result else {
            Issue.record("expected codableDecode failure for missing fields")
            return
        }
        #expect(diagnostic.stage == .codableDecode)
        #expect(diagnostic.fieldPath == "items[0].moods")
    }

    @Test("Null numeric fields are accepted instead of fabricated defaults")
    func nullNumericFieldsAreAccepted() throws {
        let current = batch(["track"])
        let json = """
        {"batchID":"\(current.batchID.uuidString)","revision":7,"mode":"full","items":[
          {"id":"track","moods":["忧郁"],"scenes":["深夜"],"energy":3,
           "acousticness":3,"danceability":3,"vocals":["女声"],"textures":[],
           "styles":[],"themes":[],"genres":[],"instruments":[],"rhythms":[],
           "semanticTags":[],"mode":"full","confidence":0.5,"tempo":null}
        ]}
        """
        let result = RecommendationIndexClassificationParser.parse(json, for: current)
        let value = try result.get()
        #expect(value.items[0].tempo == nil)
    }

    @Test("Full classification missing confidence fails at codableDecode")
    func fullClassificationMissingConfidenceFailsCodable() throws {
        let tracks = [CatalogTrackLine(
            id: "track",
            title: "track",
            artist: "Artist",
            album: "Album",
            year: nil,
            genres: [],
            language: nil,
            duration: 180,
            isFavorite: false,
            rating: nil,
            playCount: 0,
            isDownloaded: false
        )]
        let current = RecommendationIndexPreparedBatch(
            batchID: UUID(),
            revision: 7,
            checkpointGeneration: 1,
            mode: "full",
            tracks: tracks,
            pendingFixed: 0,
            pendingSemantic: 0
        )
        let json = #"{"batchID":"\#(current.batchID.uuidString)","revision":7,"mode":"full","items":[{"id":"track","moods":[],"scenes":[],"themes":[],"genres":[],"styles":[],"vocals":[],"instruments":[],"textures":[],"rhythms":[],"mode":"full"}]}"#
        let result = RecommendationIndexClassificationParser.parse(json, for: current)
        guard case let .failure(diagnostic) = result else {
            Issue.record("expected codableDecode failure for missing confidence")
            return
        }
        #expect(diagnostic.stage == .codableDecode)
        #expect(diagnostic.fieldPath == "items[0].confidence")
    }

    @Test("Legacy semanticTagsOnly mode is rejected")
    func semanticTagsOnlyModeIsRejected() throws {
        let current = batch(["track"])
        let json = #"{"batchID":"\#(current.batchID.uuidString)","revision":7,"mode":"full","items":[{"id":"track","moods":[],"scenes":[],"themes":[],"genres":[],"styles":[],"vocals":[],"instruments":[],"textures":[],"rhythms":[],"mode":"semanticTagsOnly","confidence":0.8}]}"#
        let result = RecommendationIndexClassificationParser.parse(json, for: current)
        guard case let .failure(diagnostic) = result else {
            Issue.record("expected mode failure")
            return
        }
        #expect(diagnostic.stage == .mode)
    }
}
