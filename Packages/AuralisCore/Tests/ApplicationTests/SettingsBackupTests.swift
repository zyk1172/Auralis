import Application
import Domain
import Foundation
import Testing

private func sampleBackup() -> SettingsBackup {
    SettingsBackup(
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        servers: [
            BackupServer(
                account: ServerAccount(
                    id: "backup-server",
                    displayName: "我的 NAS",
                    baseURL: URL(string: "https://music.example.com"),
                    username: "alice",
                    credentialReference: "opensubsonic.backup-server"
                ),
                secret: "s3cr3t-password"
            )
        ],
        ai: BackupAISettings(
            baseURL: "https://api.deepseek.com",
            apiPath: "/v1/chat/completions",
            model: "deepseek-chat",
            apiKey: "sk-test-123"
        ),
        musicDownload: BackupMusicDownloadSettings(
            baseURL: "http://192.168.2.24:3000",
            externalBaseURL: "https://download.example.com",
            token: "music-token"
        ),
        preferences: [
            "auralis.selected-theme": "midnight",
            "auralis.ai.enabled": "true",
            "auralis.audio.highQualityWiFi": "false",
        ]
    )
}

@Test("Backup round trip preserves server, AI and preferences")
func backupRoundTripPreservesContent() throws {
    let service = SettingsBackupService()
    let original = sampleBackup()
    let data = try service.encrypt(original, password: "backup-pass-1234")

    let restored = try service.decrypt(data, password: "backup-pass-1234")

    #expect(restored.version == SettingsBackup.currentVersion)
    #expect(restored.servers.count == 1)
    #expect(restored.servers[0].account.id == original.servers[0].account.id)
    #expect(restored.servers[0].account.baseURL == original.servers[0].account.baseURL)
    #expect(restored.servers[0].account.username == "alice")
    #expect(restored.servers[0].secret == "s3cr3t-password")
    #expect(restored.ai.baseURL == "https://api.deepseek.com")
    #expect(restored.ai.model == "deepseek-chat")
    #expect(restored.ai.apiKey == "sk-test-123")
    #expect(restored.musicDownload?.baseURL == "http://192.168.2.24:3000")
    #expect(restored.musicDownload?.externalBaseURL == "https://download.example.com")
    #expect(restored.musicDownload?.token == "music-token")
    #expect(restored.preferences["auralis.selected-theme"] == "midnight")
    #expect(restored.preferences["auralis.ai.enabled"] == "true")
    #expect(restored.preferences["auralis.audio.highQualityWiFi"] == "false")
}

@Test("Backup with wrong password fails authentication")
func backupWrongPasswordFails() throws {
    let service = SettingsBackupService()
    let data = try service.encrypt(sampleBackup(), password: "correct-horse")
    #expect(throws: SettingsBackupError.wrongPassword) {
        _ = try service.decrypt(data, password: "wrong-password")
    }
}

@Test("Backup rejects non-backup data and unsupported versions")
func backupRejectsInvalidInputs() throws {
    let service = SettingsBackupService()
    #expect(throws: SettingsBackupError.invalidFormat) {
        _ = try service.decrypt(Data("not a backup".utf8), password: "pw")
    }

    // 伪造版本号：magic + version=99 + salt + garbage
    var forged = Data("AUBK".utf8)
    forged.append(99)
    forged.append(contentsOf: Array(repeating: UInt8(0), count: 16))
    forged.append(contentsOf: Array(repeating: UInt8(7), count: 32))
    #expect(throws: SettingsBackupError.unsupportedVersion(99)) {
        _ = try service.decrypt(forged, password: "pw")
    }
}

@Test("Empty password is rejected")
func backupEmptyPasswordRejected() throws {
    let service = SettingsBackupService()
    #expect(throws: SettingsBackupError.emptyPassword) {
        _ = try service.encrypt(sampleBackup(), password: "")
    }
}

@Test("Preference whitelist only captures known keys and writes back")
func preferenceWhitelistRoundTrip() {
    let suite = "SettingsBackupTests-\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suite) else {
        Issue.record("无法创建测试 UserDefaults")
        return
    }
    defer { defaults.removePersistentDomain(forName: suite) }

    defaults.set("midnight", forKey: "auralis.selected-theme")
    defaults.set(true, forKey: "auralis.ai.enabled")
    defaults.set(false, forKey: "auralis.audio.highQualityWiFi")
    defaults.set(true, forKey: "auralis.externalMusic.enabled")
    defaults.set(true, forKey: "auralis.externalMusic.musicBrainz")
    defaults.set(false, forKey: "auralis.externalMusic.critiqueBrainz")
    defaults.set(true, forKey: "auralis.externalMusic.listenBrainz")
    // 歌曲相关 key 必须被忽略（不进入备份）
    defaults.set("some-title", forKey: "auralis.last-track")
    // 外部身份、公众指标/API 响应缓存与 V2 派生记录不属于普通设置备份。
    defaults.set("identity-cache", forKey: "auralis.externalMusic.identityCache")
    defaults.set("metrics-cache", forKey: "auralis.externalMusic.communityMetricsCache")
    defaults.set("response-cache", forKey: "auralis.externalMusic.responseCache")
    defaults.set("index-records", forKey: "auralis.recommendationIndexV2.records")

    let collected = SettingsBackupService.collectedPreferences(from: defaults)
    #expect(collected["auralis.selected-theme"] == "midnight")
    #expect(collected["auralis.ai.enabled"] == "true")
    #expect(collected["auralis.audio.highQualityWiFi"] == "false")
    #expect(collected["auralis.externalMusic.enabled"] == "true")
    #expect(collected["auralis.externalMusic.musicBrainz"] == "true")
    #expect(collected["auralis.externalMusic.critiqueBrainz"] == "false")
    #expect(collected["auralis.externalMusic.listenBrainz"] == "true")
    #expect(collected["auralis.last-track"] == nil)
    #expect(collected["auralis.externalMusic.identityCache"] == nil)
    #expect(collected["auralis.externalMusic.communityMetricsCache"] == nil)
    #expect(collected["auralis.externalMusic.responseCache"] == nil)
    #expect(collected["auralis.recommendationIndexV2.records"] == nil)

    // 写回另一组 defaults，验证恢复路径。
    let targetSuite = "SettingsBackupTests-\(UUID().uuidString)"
    guard let target = UserDefaults(suiteName: targetSuite) else {
        Issue.record("无法创建目标 UserDefaults")
        return
    }
    defer { target.removePersistentDomain(forName: targetSuite) }
    SettingsBackupService.writePreferences(collected, defaults: target)
    #expect(target.string(forKey: "auralis.selected-theme") == "midnight")
    #expect(target.bool(forKey: "auralis.ai.enabled") == true)
    #expect(target.bool(forKey: "auralis.audio.highQualityWiFi") == false)
    #expect(target.bool(forKey: "auralis.externalMusic.enabled") == true)
    #expect(target.bool(forKey: "auralis.externalMusic.musicBrainz") == true)
    #expect(target.bool(forKey: "auralis.externalMusic.critiqueBrainz") == false)
    #expect(target.bool(forKey: "auralis.externalMusic.listenBrainz") == true)
    #expect(target.string(forKey: "auralis.last-track") == nil)
    #expect(target.object(forKey: "auralis.externalMusic.identityCache") == nil)
    #expect(target.object(forKey: "auralis.externalMusic.communityMetricsCache") == nil)
    #expect(target.object(forKey: "auralis.externalMusic.responseCache") == nil)
    #expect(target.object(forKey: "auralis.recommendationIndexV2.records") == nil)
}
