// SPDX-License-Identifier: GPL-3.0-only
import Domain
import Foundation
import MusicLibrary

/// Compatibility surface for data and clients created before the Recommendation
/// Index name was finalised. New code must use the canonical `RecommendationIndex`
/// API. The persisted SQLite table and migration identifiers intentionally remain
/// unchanged because they are already on users' devices.
@available(*, deprecated, renamed: "RecommendationIndex")
public typealias RecommendationIndexV2 = RecommendationIndex
@available(*, deprecated, renamed: "RecommendationIndexStatus")
public typealias RecommendationIndexV2Status = RecommendationIndexStatus
@available(*, deprecated, renamed: "RecommendationIndexBatch")
public typealias RecommendationIndexV2Batch = RecommendationIndexBatch
@available(*, deprecated, message: "Use RecommendationIndexClassification for live v3 or LegacyRecommendationIndexClassificationV2 for v2 import")
public typealias RecommendationIndexV2Classification = LegacyRecommendationIndexClassificationV2
@available(*, deprecated, renamed: "RecommendationIndexIndexedTrack")
public typealias RecommendationIndexV2IndexedTrack = RecommendationIndexIndexedTrack
@available(*, deprecated, renamed: "RecommendationIndexCategory")
public typealias RecommendationIndexV2Category = RecommendationIndexCategory
@available(*, deprecated, renamed: "RecommendationIndexTagPage")
public typealias RecommendationIndexV2TagPage = RecommendationIndexTagPage
@available(*, deprecated, renamed: "RecommendationIndexPackage")
public typealias RecommendationIndexV2Package = RecommendationIndexPackage
@available(*, deprecated, renamed: "RecommendationIndexPackageEntry")
public typealias RecommendationIndexV2PackageEntry = RecommendationIndexPackageEntry
@available(*, deprecated, renamed: "RecommendationIndexPackageTag")
public typealias RecommendationIndexV2PackageTag = RecommendationIndexPackageTag
@available(*, deprecated, renamed: "RecommendationIndexImportStatistics")
public typealias RecommendationIndexV2ImportStatistics = RecommendationIndexImportStatistics
@available(*, deprecated, renamed: "RecommendationIndexImportError")
public typealias RecommendationIndexV2ImportError = RecommendationIndexImportError

extension LocalCatalogStore {
    @available(*, deprecated, renamed: "clearRecommendationIndex(serverID:)")
    public func clearRecommendationIndexV2(serverID: ServerID) throws {
        try clearRecommendationIndex(serverID: serverID)
    }

    @available(*, deprecated, renamed: "recommendationIndexStatus(serverID:)")
    public func recommendationIndexV2Status(serverID: ServerID?) throws -> RecommendationIndexStatus {
        try recommendationIndexStatus(serverID: serverID)
    }

    @available(*, deprecated, renamed: "nextRecommendationIndexBatch(serverID:limit:)")
    public func nextRecommendationIndexV2Batch(serverID: ServerID?, limit: Int = 80) throws -> RecommendationIndexBatch {
        try nextRecommendationIndexBatch(serverID: serverID, limit: limit)
    }

    @available(*, deprecated, renamed: "writeRecommendationIndex(_:serverID:classifier:)")
    public func writeRecommendationIndexV2(
        _ classifications: [LegacyRecommendationIndexClassificationV2],
        serverID: ServerID?,
        classifier: String = "configured-agent"
    ) throws -> Int {
        try writeRecommendationIndex(
            classifications.map(\.fixedTaxonomyClassification),
            serverID: serverID,
            classifier: classifier
        )
    }

    @available(*, deprecated, renamed: "recommendationIndexTrackIDs(serverID:query:limit:)")
    public func recommendationIndexV2TrackIDs(serverID: ServerID, query: String, limit: Int = 200) throws -> [GlobalID] {
        try recommendationIndexTrackIDs(serverID: serverID, query: query, limit: limit)
    }

    @available(*, deprecated, renamed: "readRecommendationIndex(serverID:dimension:value:limit:)")
    public func readRecommendationIndexV2(
        serverID: ServerID?, dimension: String? = nil, value: String? = nil, limit: Int = 50
    ) throws -> [RecommendationIndexIndexedTrack] {
        try readRecommendationIndex(serverID: serverID, dimension: dimension, value: value, limit: limit)
    }

    @available(*, deprecated, renamed: "recommendationIndexCategories(serverID:dimensions:)")
    public func recommendationIndexV2Categories(
        serverID: ServerID?, dimensions: Set<String>? = nil
    ) throws -> [RecommendationIndexCategory] {
        try recommendationIndexCategories(serverID: serverID, dimensions: dimensions)
    }

    @available(*, deprecated, renamed: "recommendationIndexTagCatalog(serverID:query:limit:offset:)")
    public func recommendationIndexV2TagCatalog(
        serverID: ServerID?, query: String? = nil, limit: Int = 50, offset: Int = 0
    ) throws -> RecommendationIndexTagPage {
        try recommendationIndexTagCatalog(serverID: serverID, query: query, limit: limit, offset: offset)
    }

    @available(*, deprecated, renamed: "recommendationIndexTracks(serverID:dimension:value:)")
    public func recommendationIndexV2Tracks(serverID: ServerID?, dimension: String, value: String) throws -> [Track] {
        try recommendationIndexTracks(serverID: serverID, dimension: dimension, value: value)
    }

    @available(*, deprecated, renamed: "exportRecommendationIndexPackage(serverID:)")
    public func exportRecommendationIndexV2Package(serverID: ServerID) throws -> RecommendationIndexPackage {
        try exportRecommendationIndexPackage(serverID: serverID)
    }

    @available(*, deprecated, renamed: "importRecommendationIndexPackage(data:serverID:)")
    public func importRecommendationIndexV2Package(data: Data, serverID: ServerID) throws -> RecommendationIndexImportStatistics {
        try importRecommendationIndexPackage(data: data, serverID: serverID)
    }
}
