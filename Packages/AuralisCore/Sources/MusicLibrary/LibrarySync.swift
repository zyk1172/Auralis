import Domain
import Foundation

public enum LibrarySyncMode: String, Codable, Hashable, Sendable {
    case full
    case incremental
}

public enum LibrarySyncSection: String, Codable, CaseIterable, Hashable, Sendable {
    case artists
    case albums
    case tracks
}

public struct LibrarySyncSession: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let serverID: ServerID
    public let mode: LibrarySyncMode
    public let startedAt: Date

    public init(
        id: UUID = UUID(),
        serverID: ServerID,
        mode: LibrarySyncMode,
        startedAt: Date = .now
    ) {
        self.id = id
        self.serverID = serverID
        self.mode = mode
        self.startedAt = startedAt
    }
}

public struct LibrarySyncCheckpoint: Codable, Hashable, Sendable, Identifiable {
    public var id: String { "\(sessionID.uuidString):\(section.rawValue)" }
    public let sessionID: UUID
    public let serverID: ServerID
    public let section: LibrarySyncSection
    public var continuation: String?
    public var sourceRevision: String?
    public var processedCount: Int
    public var completedAt: Date?
    public var updatedAt: Date

    public init(
        sessionID: UUID,
        serverID: ServerID,
        section: LibrarySyncSection,
        continuation: String? = nil,
        sourceRevision: String? = nil,
        processedCount: Int = 0,
        completedAt: Date? = nil,
        updatedAt: Date = .now
    ) {
        self.sessionID = sessionID
        self.serverID = serverID
        self.section = section
        self.continuation = continuation
        self.sourceRevision = sourceRevision
        self.processedCount = processedCount
        self.completedAt = completedAt
        self.updatedAt = updatedAt
    }
}

public struct LibraryPageRequest: Hashable, Sendable {
    public let mode: LibrarySyncMode
    public let continuation: String?
    public let previousRevision: String?
    public let pageSize: Int

    public init(
        mode: LibrarySyncMode,
        continuation: String? = nil,
        previousRevision: String? = nil,
        pageSize: Int
    ) {
        self.mode = mode
        self.continuation = continuation
        self.previousRevision = previousRevision
        self.pageSize = pageSize
    }
}

public struct LibraryPage<Element: Sendable>: Sendable {
    public let items: [Element]
    public let nextContinuation: String?
    public let sourceRevision: String?

    public init(
        items: [Element],
        nextContinuation: String? = nil,
        sourceRevision: String? = nil
    ) {
        self.items = items
        self.nextContinuation = nextContinuation
        self.sourceRevision = sourceRevision
    }
}

/// Network/client boundary. An OpenSubsonic adapter maps opaque continuations to offsets or
/// server-specific revision tokens; the synchronizer never depends on transport DTOs.
public protocol LibrarySyncSource: Sendable {
    func artistsPage(serverID: ServerID, request: LibraryPageRequest) async throws -> LibraryPage<Artist>
    func albumsPage(serverID: ServerID, request: LibraryPageRequest) async throws -> LibraryPage<Album>
    func tracksPage(serverID: ServerID, request: LibraryPageRequest) async throws -> LibraryPage<Track>
}

/// Transactional sync boundary. Full-sync pages remain staged until `completeSync`; incremental
/// writes are likewise hidden until completion, so readers never observe a half-applied run.
public protocol LibrarySyncStore: Sendable {
    func beginSync(serverID: ServerID, mode: LibrarySyncMode) async throws -> LibrarySyncSession
    func checkpoint(session: LibrarySyncSession, section: LibrarySyncSection) async throws -> LibrarySyncCheckpoint?
    func stageArtists(_ artists: [Artist], session: LibrarySyncSession) async throws
    func stageAlbums(_ albums: [Album], session: LibrarySyncSession) async throws
    func stageTracks(_ tracks: [Track], session: LibrarySyncSession) async throws
    func saveCheckpoint(_ checkpoint: LibrarySyncCheckpoint, session: LibrarySyncSession) async throws
    func completeSync(_ session: LibrarySyncSession, completedAt: Date) async throws
    func suspendSync(_ session: LibrarySyncSession) async
    func discardSync(_ session: LibrarySyncSession) async
}

public struct LibrarySyncRetryPolicy: Hashable, Sendable {
    public let maximumAttempts: Int
    public let initialDelayNanoseconds: UInt64
    public let multiplier: Double
    public let maximumDelayNanoseconds: UInt64

    public init(
        maximumAttempts: Int = 3,
        initialDelayNanoseconds: UInt64 = 250_000_000,
        multiplier: Double = 2,
        maximumDelayNanoseconds: UInt64 = 4_000_000_000
    ) {
        self.maximumAttempts = max(1, maximumAttempts)
        self.initialDelayNanoseconds = initialDelayNanoseconds
        self.multiplier = max(1, multiplier)
        self.maximumDelayNanoseconds = max(initialDelayNanoseconds, maximumDelayNanoseconds)
    }

    func delayNanoseconds(afterFailedAttempt attempt: Int) -> UInt64 {
        guard initialDelayNanoseconds > 0 else { return 0 }
        let exponent = max(0, attempt - 1)
        let scaled = Double(initialDelayNanoseconds) * pow(multiplier, Double(exponent))
        guard scaled.isFinite else { return maximumDelayNanoseconds }
        guard scaled < Double(maximumDelayNanoseconds) else { return maximumDelayNanoseconds }
        return UInt64(scaled)
    }
}

public protocol LibrarySyncSleeping: Sendable {
    func sleep(nanoseconds: UInt64) async throws
}

public struct TaskLibrarySyncSleeper: LibrarySyncSleeping {
    public init() {}

    public func sleep(nanoseconds: UInt64) async throws {
        guard nanoseconds > 0 else {
            try Task.checkCancellation()
            return
        }
        try await Task<Never, Never>.sleep(nanoseconds: nanoseconds)
    }
}

public struct LibrarySyncProgress: Hashable, Sendable {
    public enum Stage: String, Hashable, Sendable {
        case beginning
        case fetching
        case persisting
        case completedSection
        case completed
    }

    public let serverID: ServerID
    public let mode: LibrarySyncMode
    public let stage: Stage
    public let section: LibrarySyncSection?
    public let processedCount: Int
    public let pageCount: Int
    public let retryCount: Int

    public init(
        serverID: ServerID,
        mode: LibrarySyncMode,
        stage: Stage,
        section: LibrarySyncSection? = nil,
        processedCount: Int = 0,
        pageCount: Int = 0,
        retryCount: Int = 0
    ) {
        self.serverID = serverID
        self.mode = mode
        self.stage = stage
        self.section = section
        self.processedCount = processedCount
        self.pageCount = pageCount
        self.retryCount = retryCount
    }
}

public struct LibrarySyncReport: Hashable, Sendable {
    public let serverID: ServerID
    public let mode: LibrarySyncMode
    public let artistCount: Int
    public let albumCount: Int
    public let trackCount: Int
    public let pageCount: Int
    public let retryCount: Int
    public let startedAt: Date
    public let completedAt: Date

    public init(
        serverID: ServerID,
        mode: LibrarySyncMode,
        artistCount: Int,
        albumCount: Int,
        trackCount: Int,
        pageCount: Int,
        retryCount: Int,
        startedAt: Date,
        completedAt: Date
    ) {
        self.serverID = serverID
        self.mode = mode
        self.artistCount = artistCount
        self.albumCount = albumCount
        self.trackCount = trackCount
        self.pageCount = pageCount
        self.retryCount = retryCount
        self.startedAt = startedAt
        self.completedAt = completedAt
    }
}

public enum LibrarySyncError: Error, Equatable, Sendable {
    case alreadyRunning(ServerID)
    case invalidPageSize(Int)
    case invalidRecordServer(section: LibrarySyncSection, recordID: String, expected: ServerID, actual: ServerID)
    case duplicateRecord(section: LibrarySyncSection, recordID: String)
    case continuationLoop(section: LibrarySyncSection, continuation: String)
    case pageLimitExceeded(section: LibrarySyncSection, maximum: Int)
    case unknownSession(UUID)
    case sessionMismatch
}

public actor LibrarySynchronizer {
    public typealias ProgressHandler = @Sendable (LibrarySyncProgress) async -> Void
    public typealias RetryClassifier = @Sendable (any Error) -> Bool

    private let source: any LibrarySyncSource
    private let store: any LibrarySyncStore
    private let retryPolicy: LibrarySyncRetryPolicy
    private let sleeper: any LibrarySyncSleeping
    private let pageSize: Int
    private let maximumPagesPerSection: Int
    private let isRetryable: RetryClassifier
    private var activeServers: Set<ServerID> = []
    private var cancellationRequests: Set<ServerID> = []

    public init(
        source: any LibrarySyncSource,
        store: any LibrarySyncStore,
        pageSize: Int = 250,
        maximumPagesPerSection: Int = 100_000,
        retryPolicy: LibrarySyncRetryPolicy = .init(),
        sleeper: any LibrarySyncSleeping = TaskLibrarySyncSleeper(),
        isRetryable: @escaping RetryClassifier = LibrarySynchronizer.defaultRetryClassifier
    ) {
        self.source = source
        self.store = store
        self.pageSize = pageSize
        self.maximumPagesPerSection = max(1, maximumPagesPerSection)
        self.retryPolicy = retryPolicy
        self.sleeper = sleeper
        self.isRetryable = isRetryable
    }

    public func sync(
        serverID: ServerID,
        mode: LibrarySyncMode,
        progress: @escaping ProgressHandler = { _ in }
    ) async throws -> LibrarySyncReport {
        guard pageSize > 0 else { throw LibrarySyncError.invalidPageSize(pageSize) }
        guard activeServers.insert(serverID).inserted else {
            throw LibrarySyncError.alreadyRunning(serverID)
        }
        cancellationRequests.remove(serverID)
        defer {
            activeServers.remove(serverID)
            cancellationRequests.remove(serverID)
        }

        try checkCancellation(serverID: serverID)
        let session = try await store.beginSync(serverID: serverID, mode: mode)
        await progress(.init(serverID: serverID, mode: mode, stage: .beginning))

        var counts: [LibrarySyncSection: Int] = [:]
        var totalPages = 0
        var totalRetries = 0

        do {
            for section in LibrarySyncSection.allCases {
                let sectionResult = try await syncSection(
                    section,
                    session: session,
                    progress: progress
                )
                counts[section] = sectionResult.processedCount
                totalPages += sectionResult.pageCount
                totalRetries += sectionResult.retryCount
            }

            try checkCancellation(serverID: serverID)
            let completedAt = Date()
            try await store.completeSync(session, completedAt: completedAt)
            await progress(.init(
                serverID: serverID,
                mode: mode,
                stage: .completed,
                processedCount: counts.values.reduce(0, +),
                pageCount: totalPages,
                retryCount: totalRetries
            ))
            return LibrarySyncReport(
                serverID: serverID,
                mode: mode,
                artistCount: counts[.artists, default: 0],
                albumCount: counts[.albums, default: 0],
                trackCount: counts[.tracks, default: 0],
                pageCount: totalPages,
                retryCount: totalRetries,
                startedAt: session.startedAt,
                completedAt: completedAt
            )
        } catch {
            await store.suspendSync(session)
            throw error
        }
    }

    public func requestCancellation(serverID: ServerID) {
        guard activeServers.contains(serverID) else { return }
        cancellationRequests.insert(serverID)
    }

    public func discardSuspendedSync(serverID: ServerID, mode: LibrarySyncMode) async throws {
        guard !activeServers.contains(serverID) else {
            throw LibrarySyncError.alreadyRunning(serverID)
        }
        let session = try await store.beginSync(serverID: serverID, mode: mode)
        await store.discardSync(session)
    }

    public nonisolated static func defaultRetryClassifier(_ error: any Error) -> Bool {
        if error is CancellationError { return false }
        if error is LibrarySyncError { return false }
        return true
    }

    private struct SectionResult: Sendable {
        let processedCount: Int
        let pageCount: Int
        let retryCount: Int
    }

    private func syncSection(
        _ section: LibrarySyncSection,
        session: LibrarySyncSession,
        progress: @escaping ProgressHandler
    ) async throws -> SectionResult {
        var checkpoint = try await store.checkpoint(session: session, section: section)
        if let checkpoint, checkpoint.completedAt != nil {
            await progress(.init(
                serverID: session.serverID,
                mode: session.mode,
                stage: .completedSection,
                section: section,
                processedCount: checkpoint.processedCount
            ))
            return SectionResult(processedCount: checkpoint.processedCount, pageCount: 0, retryCount: 0)
        }

        var continuation = checkpoint?.continuation
        var previousRevision = checkpoint?.sourceRevision
        var processedCount = checkpoint?.processedCount ?? 0
        var pageCount = 0
        var retryCount = 0
        var seenContinuations = Set<String>()
        if let continuation { seenContinuations.insert(continuation) }

        while true {
            try checkCancellation(serverID: session.serverID)
            guard pageCount < maximumPagesPerSection else {
                throw LibrarySyncError.pageLimitExceeded(section: section, maximum: maximumPagesPerSection)
            }

            await progress(.init(
                serverID: session.serverID,
                mode: session.mode,
                stage: .fetching,
                section: section,
                processedCount: processedCount,
                pageCount: pageCount,
                retryCount: retryCount
            ))

            let request = LibraryPageRequest(
                mode: session.mode,
                continuation: continuation,
                previousRevision: previousRevision,
                pageSize: pageSize
            )
            let fetched = try await fetch(section: section, serverID: session.serverID, request: request)
            retryCount += fetched.retries
            pageCount += 1

            try checkCancellation(serverID: session.serverID)
            try validate(page: fetched.page, section: section, serverID: session.serverID)

            if let next = fetched.nextContinuation {
                guard seenContinuations.insert(next).inserted else {
                    throw LibrarySyncError.continuationLoop(section: section, continuation: next)
                }
            }

            await progress(.init(
                serverID: session.serverID,
                mode: session.mode,
                stage: .persisting,
                section: section,
                processedCount: processedCount,
                pageCount: pageCount,
                retryCount: retryCount
            ))
            try await stage(fetched.page, section: section, session: session)
            processedCount += fetched.itemCount
            previousRevision = fetched.sourceRevision ?? previousRevision
            continuation = fetched.nextContinuation
            checkpoint = LibrarySyncCheckpoint(
                sessionID: session.id,
                serverID: session.serverID,
                section: section,
                continuation: continuation,
                sourceRevision: previousRevision,
                processedCount: processedCount,
                completedAt: continuation == nil ? .now : nil
            )
            try await store.saveCheckpoint(checkpoint!, session: session)

            guard continuation != nil else { break }
        }

        await progress(.init(
            serverID: session.serverID,
            mode: session.mode,
            stage: .completedSection,
            section: section,
            processedCount: processedCount,
            pageCount: pageCount,
            retryCount: retryCount
        ))
        return SectionResult(processedCount: processedCount, pageCount: pageCount, retryCount: retryCount)
    }

    private enum FetchedPage: Sendable {
        case artists(LibraryPage<Artist>, retries: Int)
        case albums(LibraryPage<Album>, retries: Int)
        case tracks(LibraryPage<Track>, retries: Int)

        var retries: Int {
            switch self {
            case let .artists(_, retries), let .albums(_, retries), let .tracks(_, retries): retries
            }
        }

        var itemCount: Int {
            switch self {
            case let .artists(page, _): page.items.count
            case let .albums(page, _): page.items.count
            case let .tracks(page, _): page.items.count
            }
        }

        var nextContinuation: String? {
            switch self {
            case let .artists(page, _): page.nextContinuation
            case let .albums(page, _): page.nextContinuation
            case let .tracks(page, _): page.nextContinuation
            }
        }

        var sourceRevision: String? {
            switch self {
            case let .artists(page, _): page.sourceRevision
            case let .albums(page, _): page.sourceRevision
            case let .tracks(page, _): page.sourceRevision
            }
        }

        var page: FetchedPage { self }
    }

    private func fetch(
        section: LibrarySyncSection,
        serverID: ServerID,
        request: LibraryPageRequest
    ) async throws -> FetchedPage {
        switch section {
        case .artists:
            let result = try await withRetry(serverID: serverID) {
                try await self.source.artistsPage(serverID: serverID, request: request)
            }
            return .artists(result.value, retries: result.retries)
        case .albums:
            let result = try await withRetry(serverID: serverID) {
                try await self.source.albumsPage(serverID: serverID, request: request)
            }
            return .albums(result.value, retries: result.retries)
        case .tracks:
            let result = try await withRetry(serverID: serverID) {
                try await self.source.tracksPage(serverID: serverID, request: request)
            }
            return .tracks(result.value, retries: result.retries)
        }
    }

    private func stage(
        _ page: FetchedPage,
        section: LibrarySyncSection,
        session: LibrarySyncSession
    ) async throws {
        switch (section, page) {
        case let (.artists, .artists(page, _)):
            try await store.stageArtists(page.items, session: session)
        case let (.albums, .albums(page, _)):
            try await store.stageAlbums(page.items, session: session)
        case let (.tracks, .tracks(page, _)):
            try await store.stageTracks(page.items, session: session)
        default:
            throw LibrarySyncError.sessionMismatch
        }
    }

    private func validate(page: FetchedPage, section: LibrarySyncSection, serverID: ServerID) throws {
        let records: [(ServerID, String)]
        switch page {
        case let .artists(page, _): records = page.items.map { ($0.serverID, $0.id.rawValue) }
        case let .albums(page, _): records = page.items.map { ($0.serverID, $0.id.rawValue) }
        case let .tracks(page, _): records = page.items.map { ($0.serverID, $0.id.rawValue) }
        }

        var seen = Set<String>()
        for (recordServer, recordID) in records {
            guard recordServer == serverID else {
                throw LibrarySyncError.invalidRecordServer(
                    section: section,
                    recordID: recordID,
                    expected: serverID,
                    actual: recordServer
                )
            }
            guard seen.insert(recordID).inserted else {
                throw LibrarySyncError.duplicateRecord(section: section, recordID: recordID)
            }
        }
    }

    private func withRetry<Value: Sendable>(
        serverID: ServerID,
        operation: @Sendable () async throws -> Value
    ) async throws -> (value: Value, retries: Int) {
        var attempt = 1
        while true {
            try checkCancellation(serverID: serverID)
            do {
                return (try await operation(), attempt - 1)
            } catch {
                if error is CancellationError { throw error }
                guard attempt < retryPolicy.maximumAttempts, isRetryable(error) else { throw error }
                let delay = retryPolicy.delayNanoseconds(afterFailedAttempt: attempt)
                attempt += 1
                try await sleeper.sleep(nanoseconds: delay)
            }
        }
    }

    private func checkCancellation(serverID: ServerID) throws {
        try Task.checkCancellation()
        if cancellationRequests.contains(serverID) { throw CancellationError() }
    }
}
