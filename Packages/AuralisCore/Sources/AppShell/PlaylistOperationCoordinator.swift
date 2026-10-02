// SPDX-License-Identifier: GPL-3.0-only
import Domain
import Foundation

/// Serializes a playlist's reads, writes and persistence across MainActor suspension.
/// Callers revalidate the browsing session after acquiring and after remote awaits.
@MainActor
final class PlaylistOperationCoordinator {
    private var held: Set<GlobalID> = []
    private var waiting: [GlobalID: [CheckedContinuation<Void, Never>]] = [:]

    func acquire(_ id: GlobalID) async {
        if held.insert(id).inserted { return }
        await withCheckedContinuation { waiting[id, default: []].append($0) }
    }

    func release(_ id: GlobalID) {
        if var queue = waiting[id], !queue.isEmpty {
            let next = queue.removeFirst()
            waiting[id] = queue.isEmpty ? nil : queue
            next.resume()
        } else {
            held.remove(id)
        }
    }
}
