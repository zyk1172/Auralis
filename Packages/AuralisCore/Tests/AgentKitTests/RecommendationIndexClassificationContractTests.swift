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
        styles: String
    ) -> String {
        """
        {"id":"\(id)","moods":\(moods),"scenes":\(scenes),"energy":3,"tempo":3,
         "acousticness":3,"danceability":3,"vocals":\(vocals),"textures":\(textures),
         "styles":\(styles),"semanticTags":[{"value":"夜行感","confidence":0.8}],
         "mode":"full","confidence":0.9}
        """
    }

    @Test("Scalar taxonomy values decode as single-element string arrays")
    func scalarTaxonomyValuesAreCompatible() throws {
        let current = batch(["track"])
        let item = envelopeJSON(
            "track",
            moods: #"["怀旧"]"#,
            scenes: #""深夜""#,
            vocals: #""女声""#,
            textures: #""钢琴""#,
            styles: #""流行""#
        )
        let json = #"{"batchID":"\#(current.batchID.uuidString)","revision":7,"mode":"full","items":[\#(item)]}"#
        let result = RecommendationIndexClassificationParser.parse(json, for: current)
        let value = try result.get()
        #expect(value.items[0].moods == ["怀旧"])
        #expect(value.items[0].scenes == ["深夜"])
        #expect(value.items[0].vocals == ["女声"])
        #expect(value.items[0].textures == ["钢琴"])
        #expect(value.items[0].styles == ["流行"])
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
          "textures":["钢琴"],"styles":["流行"],"semanticTags":"怀旧",
          "mode":"full","confidence":0.9}]}
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

    @Test("Synonym values fail at taxonomy stage before commit")
    func synonymTaxonomyFails() throws {
        let current = batch(["track"])
        let item = envelopeJSON("track", moods: #"["伤感"]"#, scenes: #"["夜晚"]"#, vocals: #"["女声"]"#, textures: #"["柔和"]"#, styles: #"["流行音乐"]"#)
        let json = #"{"batchID":"\#(current.batchID.uuidString)","revision":7,"mode":"full","items":[\#(item)]}"#
        let result = RecommendationIndexClassificationParser.parse(json, for: current)
        guard case let .failure(diagnostic) = result else {
            Issue.record("expected taxonomy failure")
            return
        }
        #expect(diagnostic.stage == .taxonomy)
    }

    @Test("Mixed canonical and synonym values fail atomically")
    func mixedTaxonomyFails() throws {
        let current = batch(["track"])
        let item = envelopeJSON("track", moods: #"["忧郁","伤感"]"#, scenes: #"["深夜"]"#, vocals: #"["女声"]"#, textures: #"[]"#, styles: #"[]"#)
        let json = #"{"batchID":"\#(current.batchID.uuidString)","revision":7,"mode":"full","items":[\#(item)]}"#
        let result = RecommendationIndexClassificationParser.parse(json, for: current)
        guard case let .failure(diagnostic) = result else {
            Issue.record("expected taxonomy failure for mixed values")
            return
        }
        #expect(diagnostic.stage == .taxonomy)
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
           "styles":["流行"],"semanticTags":["夜行感"],"mode":"full","confidence":0.9}
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

    @Test("Full classification rejects null required fields")
    func fullClassificationNullFieldsFailCodable() throws {
        let current = batch(["track"])
        let json = """
        {"batchID":"\(current.batchID.uuidString)","revision":7,"mode":"full","items":[
          {"id":"track","moods":["忧郁"],"scenes":["深夜"],"energy":3,
           "acousticness":3,"danceability":3,"vocals":["女声"],"textures":[],
           "styles":[],"semanticTags":[],"mode":"full","confidence":0.5,"tempo":null}
        ]}
        """
        let result = RecommendationIndexClassificationParser.parse(json, for: current)
        guard case let .failure(diagnostic) = result else {
            Issue.record("expected codableDecode failure for null field")
            return
        }
        #expect(diagnostic.stage == .codableDecode)
        #expect(diagnostic.fieldPath == "items[0].tempo")
    }

    @Test("semanticTagsOnly still requires its full item contract")
    func semanticTagsOnlyMissingFieldsFailCodable() throws {
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
            mode: "semanticTagsOnly",
            tracks: tracks,
            pendingFixed: 0,
            pendingSemantic: 1
        )
        let json = #"{"batchID":"\#(current.batchID.uuidString)","revision":7,"mode":"semanticTagsOnly","items":[{"id":"track","semanticTags":[],"mode":"semanticTagsOnly"}]}"#
        let result = RecommendationIndexClassificationParser.parse(json, for: current)
        guard case let .failure(diagnostic) = result else {
            Issue.record("expected codableDecode failure for semanticTagsOnly missing confidence")
            return
        }
        #expect(diagnostic.stage == .codableDecode)
        #expect(diagnostic.fieldPath == "items[0].confidence")
    }
}
