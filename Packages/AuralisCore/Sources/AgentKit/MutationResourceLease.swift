import Foundation

/// Real-world resources whose mutations must not overlap across sessions.
/// Read-only/model work does not acquire one of these resources.
public enum MutationResource: String, Codable, Sendable, Hashable, CaseIterable {
    case playback
    case queue
    case playlist
    case recommendationIndex
    case download
    case server
    case memory
    case annotation
    case customTool
}

/// Actor-isolated, non-reentrant resource ownership.
///
/// A second conflicting mutation is rejected before it reaches a bridge. This
/// keeps the safety boundary deterministic without introducing a hidden Agent
/// round limit or making unrelated resources wait for one global lease.
public actor MutationResourceLeaseRegistry {
    public static let shared = MutationResourceLeaseRegistry()

    private struct Ownership: Sendable {
        let owner: UUID
        var holdCount: Int
    }

    private var owners: [MutationResource: Ownership] = [:]

    public init() {}

    public func tryAcquire(
        _ resources: Set<MutationResource>,
        owner: UUID
    ) -> Bool {
        guard !resources.isEmpty else { return true }
        guard resources.allSatisfy({ owners[$0]?.owner == nil || owners[$0]?.owner == owner }) else {
            return false
        }
        for resource in resources {
            if var ownership = owners[resource], ownership.owner == owner {
                ownership.holdCount += 1
                owners[resource] = ownership
            } else {
                owners[resource] = Ownership(owner: owner, holdCount: 1)
            }
        }
        return true
    }

    public func release(
        _ resources: Set<MutationResource>,
        owner: UUID
    ) {
        for resource in resources {
            guard var ownership = owners[resource], ownership.owner == owner else { continue }
            ownership.holdCount -= 1
            if ownership.holdCount <= 0 {
                owners[resource] = nil
            } else {
                owners[resource] = ownership
            }
        }
    }

    public func owner(of resource: MutationResource) -> UUID? {
        owners[resource]?.owner
    }

    /// Number of active acquisitions held by `owner`. This is intentionally
    /// exposed for diagnostics/tests only; callers must still release exactly
    /// once for every successful acquisition.
    public func holdCount(of resource: MutationResource, by owner: UUID) -> Int {
        guard let ownership = owners[resource], ownership.owner == owner else { return 0 }
        return ownership.holdCount
    }

    public func isHeld(
        _ resources: Set<MutationResource>,
        by owner: UUID
    ) -> Bool {
        resources.allSatisfy { owners[$0]?.owner == owner }
    }
}

extension ToolDescriptor {
    /// Maps a canonical descriptor to the smallest real resource it mutates.
    /// This is derived from the same authorization operation used by
    /// SideEffectAuthorizationContext, so a new write cannot silently bypass
    /// resource serialization by choosing a different tool spelling.
    public var mutationResources: Set<MutationResource> {
        guard permission != .readOnly else { return [] }
        if !derivedMutationResources.isEmpty {
            return derivedMutationResources
        }
        guard let operation = authorizationOperation else {
            return sideEffectPolicy.resourceFallback
        }
        switch operation {
        case .playbackPlay, .playbackPause, .playbackNavigation, .playbackSeek, .playbackMode, .playbackTimer:
            return [.playback]
        case .queueAppend, .queuePlayNext, .queueReplace, .queueClear, .queueRemove, .queueMove, .queueShuffle:
            return [.queue]
        case .playlistCreate, .playlistAdd, .playlistRemove, .playlistMove, .playlistRename,
             .playlistDuplicate, .playlistMerge, .playlistDelete, .playlistSaveQueue:
            return [.playlist]
        case .recommendationIndexWrite:
            return [.recommendationIndex]
        case .favoriteSet, .ratingSet, .dislikedSet:
            return [.annotation]
        case .serverSync, .serverSwitch, .serverRemove, .serverConfigure:
            return [.server]
        case .downloadSubmit, .downloadHistoryRemove, .downloadHistoryClean, .offlineDownload:
            return [.download]
        case .memorySave, .memoryDelete, .memoryClear, .skillCreate, .skillDelete:
            return [.memory]
        case .customToolCreate, .customToolUpdate, .customToolEnable, .customToolDisable,
             .customToolDelete, .customToolRepair:
            return [.customTool]
        }
    }
}

private extension ToolSideEffectPolicy {
    var resourceFallback: Set<MutationResource> {
        switch self {
        case .none: return [.annotation]
        case .playback: return [.playback]
        case .queue: return [.queue]
        case .playlist: return [.playlist]
        case .annotation: return [.annotation]
        case .server: return [.server]
        case .download: return [.download]
        case .memory: return [.memory]
        }
    }
}
