// SPDX-License-Identifier: GPL-3.0-only
import Application
import Foundation
import SecurityKit

/// Restores connection secrets first, then commits their public settings together.
/// Missing/empty secrets mean unconfigured, never reuse a previous endpoint's key.
@MainActor
enum BackupConnectionRestorer {
    enum RestoreError: LocalizedError {
        case credentialRollbackFailed

        var errorDescription: String? { "恢复凭据失败，连接已停用，请重新配置接口。" }
    }

    static func restore(
        _ backup: SettingsBackup,
        defaults: UserDefaults,
        vault: any CredentialVault
    ) async throws {
        var replacements: [(CredentialID, String?)] = [(AIConnectionSettings.credentialID, backup.ai.apiKey)]
        if let download = backup.musicDownload {
            replacements.append((MoviePilotSettings.tokenCredentialID, download.token))
        }
        var previous: [(CredentialID, String?)] = []
        for (id, _) in replacements {
            do { previous.append((id, try await vault.retrieve(id: id))) }
            catch CredentialVaultError.missing { previous.append((id, nil)) }
        }
        var attempted = 0
        do {
            for (id, value) in replacements {
                attempted += 1
                try Task.checkCancellation()
                if let value, !value.isEmpty { try await vault.store(value, for: id) }
                else { try await vault.delete(id: id) }
            }
            try Task.checkCancellation()
        } catch {
            var rollbackFailed = false
            for (id, value) in previous.prefix(attempted).reversed() {
                do {
                    if let value { try await vault.store(value, for: id) }
                    else { try await vault.delete(id: id) }
                } catch { rollbackFailed = true }
            }
            if rollbackFailed {
                defaults.set("", forKey: AIConnectionSettings.Keys.baseURL)
                defaults.set("", forKey: MoviePilotSettings.baseURLKey)
                throw RestoreError.credentialRollbackFailed
            }
            throw error
        }
        // No suspension while publishing the new public configuration.
        SettingsBackupService.writePreferences(backup.preferences, defaults: defaults)
        defaults.set(backup.ai.baseURL, forKey: AIConnectionSettings.Keys.baseURL)
        defaults.set(backup.ai.apiPath, forKey: AIConnectionSettings.Keys.apiPath)
        defaults.set(backup.ai.model, forKey: AIConnectionSettings.Keys.model)
        defaults.set(
            backup.ai.endpointMode ?? AIEndpointMode.infer(from: backup.ai.apiPath).rawValue,
            forKey: AIConnectionSettings.Keys.endpointMode
        )
        if let download = backup.musicDownload {
            defaults.set(download.baseURL, forKey: MoviePilotSettings.baseURLKey)
            defaults.set(download.externalBaseURL, forKey: MoviePilotSettings.externalBaseURLKey)
        }
        defaults.removeObject(forKey: AIConnectionSettings.Keys.verifiedCapabilities)
    }
}
