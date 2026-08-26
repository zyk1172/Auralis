import AgentKit
import AIKit
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
            tracks: tracks,
            pendingFixed: tracks.count
        )
    }

    private func envelope(_ current: RecommendationIndexPreparedBatch, item: String) -> String {
        #"{"batchID":"\#(current.batchID.uuidString)","revision":\#(current.revision),"items":[\#(item)]}"#
    }

    private func envelope(_ current: RecommendationIndexPreparedBatch, items: [String]) -> String {
        #"{"batchID":"\#(current.batchID.uuidString)","revision":\#(current.revision),"items":[\#(items.joined(separator: ","))]}"#
    }

    @Test("DeepSeek-style v3 output without item mode parses successfully")
    func deepSeekStyleOutputWithoutItemModeSucceeds() throws {
        let current = batch(["track"])
        let json = envelope(
            current,
            item: #"{"id":"track","moods":["mood.sacred"],"genres":["genre.classical"],"instruments":["instrument.piano"]}"#
        )

        let value = try RecommendationIndexClassificationParser.parse(json, for: current).get().items[0]
        #expect(value.moods == ["mood.sacred"])
        #expect(value.genres == ["genre.classical"])
        #expect(value.instruments == ["instrument.piano"])
        #expect(value.scenes.isEmpty)
        #expect(value.themes.isEmpty)
        #expect(value.styles.isEmpty)
        #expect(value.vocals.isEmpty)
        #expect(value.textures.isEmpty)
        #expect(value.rhythms.isEmpty)
        #expect(value.energy == nil)
        #expect(value.tempo == nil)
        #expect(value.acousticness == nil)
        #expect(value.danceability == nil)
        #expect(value.instrumentalness == nil)
        #expect(value.liveness == nil)
        #expect(value.speechiness == nil)
        #expect(value.valence == nil)
        #expect(value.complexity == nil)
        #expect(value.confidence == 0.5)
    }

    @Test("Missing categorical fields default to empty arrays")
    func missingCategoricalFieldsDefaultToEmptyArrays() throws {
        let current = batch(["track"])
        let value = try RecommendationIndexClassificationParser.parse(
            envelope(current, item: #"{"id":"track"}"#),
            for: current
        ).get().items[0]

        #expect(value.moods.isEmpty)
        #expect(value.scenes.isEmpty)
        #expect(value.themes.isEmpty)
        #expect(value.genres.isEmpty)
        #expect(value.styles.isEmpty)
        #expect(value.vocals.isEmpty)
        #expect(value.instruments.isEmpty)
        #expect(value.textures.isEmpty)
        #expect(value.rhythms.isEmpty)
    }

    @Test("Missing numeric fields remain nil")
    func missingNumericFieldsRemainNil() throws {
        let current = batch(["track"])
        let value = try RecommendationIndexClassificationParser.parse(
            envelope(current, item: #"{"id":"track","moods":["mood.calm"]}"#),
            for: current
        ).get().items[0]

        #expect(value.energy == nil)
        #expect(value.tempo == nil)
        #expect(value.acousticness == nil)
        #expect(value.danceability == nil)
        #expect(value.instrumentalness == nil)
        #expect(value.liveness == nil)
        #expect(value.speechiness == nil)
        #expect(value.valence == nil)
        #expect(value.complexity == nil)
    }

    @Test("Numeric values keep valid integers and drop only out-of-range values")
    func numericValuesAreTolerantAndBounded() throws {
        let current = batch(["max", "tooHigh", "tooLow", "tempoMax", "tempoTooHigh", "string", "null", "missing"])
        let valueByID = Dictionary(
            uniqueKeysWithValues: try RecommendationIndexClassificationParser.parse(
                envelope(
                    current,
                    items: [
                        #"{"id":"max","energy":10}"#,
                        #"{"id":"tooHigh","energy":11}"#,
                        #"{"id":"tooLow","energy":0}"#,
                        #"{"id":"tempoMax","tempo":5}"#,
                        #"{"id":"tempoTooHigh","tempo":6}"#,
                        #"{"id":"string","danceability":"3"}"#,
                        #"{"id":"null","valence":null}"#,
                        #"{"id":"missing"}"#
                    ]
                ),
                for: current
            ).get().items.map { ($0.id, $0) }
        )

        #expect(valueByID["max"]?.energy == 10)
        #expect(valueByID["tooHigh"]?.energy == nil)
        #expect(valueByID["tooLow"]?.energy == nil)
        #expect(valueByID["tempoMax"]?.tempo == 5)
        #expect(valueByID["tempoTooHigh"]?.tempo == nil)
        #expect(valueByID["string"]?.danceability == 3)
        #expect(valueByID["null"]?.valence == nil)
        #expect(valueByID["missing"]?.energy == nil)
    }

    @Test("One out-of-range numeric value does not discard a sixteen-track batch")
    func outOfRangeNumericValueDoesNotKillBatch() throws {
        let ids = (0..<16).map { "track-\($0)" }
        let current = batch(ids)
        let items = ids.map { id in
            let energy = id == "track-7" ? "11" : "8"
            return #"{"id":"\#(id)","moods":["mood.sacred"],"energy":\#(energy)}"#
        }

        let values = try RecommendationIndexClassificationParser.parse(
            envelope(current, items: items),
            for: current
        ).get().items

        #expect(values.count == 16)
        #expect(values.first(where: { $0.id == "track-7" })?.energy == nil)
        #expect(values.allSatisfy { $0.moods == ["mood.sacred"] })
    }

    @Test("Float numeric values remain a repairable Codable diagnostic")
    func floatNumericValueIsDiagnosed() throws {
        let current = batch(["track"])
        let result = RecommendationIndexClassificationParser.parse(
            envelope(current, item: #"{"id":"track","energy":3.5}"#),
            for: current
        )

        guard case let .failure(diagnostic) = result else {
            Issue.record("expected codableDecode failure")
            return
        }
        #expect(diagnostic.stage == .codableDecode)
        #expect(diagnostic.fieldPath == "items[0].energy")
        #expect(diagnostic.expectedType == "integer")
        #expect(diagnostic.actualType == "number")
    }

    @Test("Null categorical fields also default to empty arrays")
    func nullCategoricalFieldsDefaultToEmptyArrays() throws {
        let current = batch(["track"])
        let value = try RecommendationIndexClassificationParser.parse(
            envelope(
                current,
                item: #"{"id":"track","moods":null,"scenes":null,"themes":null,"genres":null,"styles":null,"vocals":null,"instruments":null,"textures":null,"rhythms":null}"#
            ),
            for: current
        ).get().items[0]

        #expect(value.moods.isEmpty)
        #expect(value.scenes.isEmpty)
        #expect(value.themes.isEmpty)
        #expect(value.genres.isEmpty)
        #expect(value.styles.isEmpty)
        #expect(value.vocals.isEmpty)
        #expect(value.instruments.isEmpty)
        #expect(value.textures.isEmpty)
        #expect(value.rhythms.isEmpty)
    }

    @Test("Missing confidence uses the safe fallback")
    func missingConfidenceUsesSafeFallback() throws {
        let current = batch(["track"])
        let value = try RecommendationIndexClassificationParser.parse(
            envelope(current, item: #"{"id":"track","moods":["mood.calm"]}"#),
            for: current
        ).get().items[0]
        #expect(value.confidence == 0.5)
    }

    @Test("Legacy semanticTags and mode extras cannot affect v3 parsing")
    func legacyExtrasAreIgnoredByV3Parser() throws {
        let current = batch(["track"])
        let json = envelope(
            current,
            item: #"{"id":"track","moods":["mood.sacred"],"semanticTags":["夜行感"],"mode":"semanticTagsOnly"}"#
        )
        let value = try RecommendationIndexClassificationParser.parse(json, for: current).get()
        #expect(value.items[0].moods == ["mood.sacred"])
    }

    @Test("Scalar categorical values remain a local compatibility repair")
    func scalarCategoricalValuesAreCompatible() throws {
        let current = batch(["track"])
        let value = try RecommendationIndexClassificationParser.parse(
            envelope(current, item: #"{"id":"track","moods":"mood.sacred"}"#),
            for: current
        ).get().items[0]
        #expect(value.moods == ["mood.sacred"])
    }

    @Test("Wrong categorical object shape remains a repairable Codable diagnostic")
    func wrongCategoricalObjectShapeIsDiagnosed() throws {
        let current = batch(["track"])
        let result = RecommendationIndexClassificationParser.parse(
            envelope(current, item: #"{"id":"track","vocals":{}}"#),
            for: current
        )

        guard case let .failure(diagnostic) = result else {
            Issue.record("expected codableDecode failure")
            return
        }
        #expect(diagnostic.stage == .codableDecode)
        #expect(diagnostic.fieldPath == "items[0].vocals")
        #expect(diagnostic.expectedType == "string[]")
        #expect(diagnostic.actualType == "object")
    }

    @Test("Canonical display and alias values resolve to one fixed TagID")
    func fixedTaxonomyNamesCanonicalize() throws {
        let current = batch(["track"])
        let value = try RecommendationIndexClassificationParser.parse(
            envelope(
                current,
                item: #"{"id":"track","moods":["mood.sacred","神圣","圣洁"]}"#
            ),
            for: current
        ).get().items[0]
        #expect(value.moods == ["mood.sacred"])
    }

    @Test("Canonical IDs reroute to their owning dimension and unknown values drop")
    func canonicalIDsRerouteAndUnknownValuesDrop() throws {
        let current = batch(["track"])
        let value = try RecommendationIndexClassificationParser.parse(
            envelope(
                current,
                item: #"{"id":"track","moods":["instrument.piano","仙气飘飘神曲感"]}"#
            ),
            for: current
        ).get().items[0]
        #expect(value.moods.isEmpty)
        #expect(value.instruments == ["instrument.piano"])
    }

    @Test("Dimension-aware warm display names resolve independently")
    func warmDisplayNamesResolveByExpectedDimension() throws {
        let current = batch(["track"])
        let value = try RecommendationIndexClassificationParser.parse(
            envelope(
                current,
                item: #"{"id":"track","moods":["温暖"],"textures":["温暖"]}"#
            ),
            for: current
        ).get().items[0]
        #expect(value.moods == ["mood.warm"])
        #expect(value.textures == ["texture.warm"])
    }

    @Test("Missing required identity is diagnosed before Codable defaults")
    func missingIdentityIsFatal() throws {
        let current = batch(["track"])
        let result = RecommendationIndexClassificationParser.parse(
            envelope(current, item: #"{"moods":[]}"#),
            for: current
        )
        guard case let .failure(diagnostic) = result else {
            Issue.record("expected missing id failure")
            return
        }
        #expect(diagnostic.stage == .codableDecode)
        #expect(diagnostic.fieldPath == "items[0].id")
        #expect(diagnostic.expectedType == "required")
        #expect(diagnostic.actualType == "missing")
    }

    @Test("V3 Codable output has no legacy semanticTags or mode keys")
    func v3CodableOutputHasNoLegacyKeys() throws {
        let item = RecommendationIndexClassification(id: "track", moods: ["mood.sacred"])
        let object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(item)) as? [String: Any]
        )
        #expect(object["semanticTags"] == nil)
        #expect(object["legacySemanticTags"] == nil)
        #expect(object["mode"] == nil)

        let current = batch(["track"])
        let envelopeObject = try #require(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(
                    RecommendationIndexClassificationEnvelope(
                        batchID: current.batchID,
                        revision: current.revision,
                        items: [item]
                    )
                )
            ) as? [String: Any]
        )
        #expect(envelopeObject["mode"] == nil)
    }

    @Test("Hidden commit schema has no legacy item mode")
    func hiddenCommitSchemaHasNoLegacyItemMode() throws {
        let descriptor = try #require(
            AgentToolRegistry.all.first(where: { $0.name == "recommendation_index_commit" })
        )
        let itemsSchema = try #require(
            descriptor.parameters.first(where: { $0.name == "items" })?.schemaJSON
        )
        #expect(!itemsSchema.contains("\"mode\""))
    }

    @Test("Strict schema contains fixed enums and requires nullable numeric properties")
    func strictSchemaUsesFixedTaxonomyAndNullableRequiredNumerics() throws {
        let schema = try #require(
            JSONSerialization.jsonObject(
                with: RecommendationIndexSkillRuntime.outputSchema().jsonData
            ) as? [String: Any]
        )
        let rootRequired = try #require(schema["required"] as? [String])
        #expect(rootRequired == ["batchID", "revision", "items"])
        let rootProperties = try #require(schema["properties"] as? [String: Any])
        #expect(rootProperties["mode"] == nil)

        let items = try #require(rootProperties["items"] as? [String: Any])
        let itemSchema = try #require(items["items"] as? [String: Any])
        let itemProperties = try #require(itemSchema["properties"] as? [String: Any])
        let itemRequired = try #require(itemSchema["required"] as? [String])
        #expect(itemProperties["mode"] == nil)
        #expect(itemProperties["semanticTags"] == nil)
        for key in ["energy", "tempo", "acousticness", "danceability", "instrumentalness", "liveness", "speechiness", "valence", "complexity"] {
            #expect(itemRequired.contains(key))
            let numeric = try #require(itemProperties[key] as? [String: Any])
            #expect(numeric["anyOf"] != nil)
        }
        let moods = try #require(itemProperties["moods"] as? [String: Any])
        let moodItems = try #require(moods["items"] as? [String: Any])
        let moodEnum = try #require(moodItems["enum"] as? [String])
        #expect(moodEnum.contains("mood.sacred"))
    }

    @Test("Legacy diagnostics still decode optional shape metadata")
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
}
