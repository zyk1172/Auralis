// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

/// Reconciles answer deltas with final snapshots. Final text is not another delta: append only
/// the missing suffix, and keep independent output/content parts separate.
struct StreamingAnswerBuffer: Sendable {
    struct Part: Hashable, Sendable {
        var output = 0
        var content = 0
    }
    private var text: [Part: String] = [:]
    private var finalized: Set<Part> = []
    private var emitted = ""

    mutating func append(_ delta: String, part: Part = .init()) -> String {
        guard !finalized.contains(part) else { return "" }
        text[part, default: ""] += delta
        emitted += delta
        return delta
    }

    mutating func snapshot(_ snapshot: String, part: Part = .init()) -> String {
        let previous = text[part, default: ""]
        // A differing snapshot cannot safely be spliced into an append-only event stream.
        guard snapshot.hasPrefix(previous) else { return "" }
        text[part] = snapshot
        finalized.insert(part)
        let suffix = String(snapshot.dropFirst(previous.count))
        emitted += suffix
        return suffix
    }

    mutating func completeSnapshot(_ snapshot: String) -> String {
        guard snapshot.hasPrefix(emitted) else { return "" }
        let suffix = String(snapshot.dropFirst(emitted.count))
        emitted = snapshot
        return suffix
    }
}
