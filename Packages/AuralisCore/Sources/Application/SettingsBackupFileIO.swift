// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Keeps synchronous key derivation, encryption and file I/O off the UI actor.
public actor SettingsBackupFileIO {
    public static let shared = SettingsBackupFileIO()
    private let service = SettingsBackupService()

    public func write(_ backup: SettingsBackup, password: String, to url: URL) throws {
        try Task.checkCancellation()
        let data = try service.encrypt(backup, password: password)
        try Task.checkCancellation()
        try data.write(to: url, options: .atomic)
    }

    public func read(from url: URL, password: String) throws -> SettingsBackup {
        try Task.checkCancellation()
        let data = try Data(contentsOf: url)
        let backup = try service.decrypt(data, password: password)
        try Task.checkCancellation()
        return backup
    }
}
