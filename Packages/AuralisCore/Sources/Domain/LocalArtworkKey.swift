// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Encodes an app-local artwork file into the existing string artwork-key boundary without
/// pretending the file belongs to an OpenSubsonic server. The modification timestamp is part of
/// the key so replacing a sidecar cover naturally invalidates image caches.
public enum LocalArtworkKey {
    public static let prefix = "auralis-local-artwork:"

    public static func make(fileURL: URL) -> String {
        let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey])
        let modifiedAt = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
        let payload = "\(fileURL.standardizedFileURL.absoluteString)\n\(modifiedAt)"
        return prefix + Data(payload.utf8).base64EncodedString()
    }

    public static func fileURL(from key: String) -> URL? {
        guard key.hasPrefix(prefix) else { return nil }
        let encoded = String(key.dropFirst(prefix.count))
        guard let data = Data(base64Encoded: encoded),
              let payload = String(data: data, encoding: .utf8),
              let firstLine = payload.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first,
              let url = URL(string: String(firstLine)),
              url.isFileURL
        else { return nil }
        return url
    }
}
