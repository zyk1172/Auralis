import XCTest

@MainActor
final class AuralisMusicHapticsUITests: XCTestCase {
    private let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
        app.terminate()
    }

    func testPlaybackSettingsAlwaysExposeMusicHaptics() throws {
        app.launchArguments = ["-auralis-ui-smoke"]
        app.launch()

        let library = app.buttons["音乐库"].firstMatch
        XCTAssertTrue(library.waitForExistence(timeout: 15), "iOS AppShell did not expose the library entry point")
        library.tap()

        let settings = app.buttons["设置"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 10), "LibraryView did not expose its settings entry point")
        settings.tap()

        let playback = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "播放与音质")).firstMatch
        XCTAssertTrue(playback.waitForExistence(timeout: 10), "SettingsView is not the AppShell settings view used by the app")
        playback.tap()

        let section = app.staticTexts["音乐震动反馈"].firstMatch
        XCTAssertTrue(section.waitForExistence(timeout: 10), "Music Haptics section is missing from the playback settings page")

        // The stable identifier must resolve when the test device exposes a
        // Core Haptics switch.  On unsupported hardware the section remains
        // discoverable and the support row is the fallback proof instead.
        let toggle = app.switches["auralis.settings.musicHaptics"].firstMatch
        if toggle.waitForExistence(timeout: 3) {
            XCTAssertTrue(toggle.exists)
        } else {
            XCTAssertTrue(
                app.staticTexts["设备支持 Core Haptics"].waitForExistence(timeout: 5),
                "Unsupported hardware must show the support fallback instead of hiding the feature"
            )
        }

#if DEBUG
        let diagnostics = app.buttons["Music Haptics 调试诊断"].firstMatch
        XCTAssertTrue(diagnostics.waitForExistence(timeout: 5), "DEBUG diagnostics must be reachable even without haptic hardware")
        diagnostics.tap()
        XCTAssertTrue(app.staticTexts["Build provenance"].waitForExistence(timeout: 5))
        let commit = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", ".*[0-9a-fA-F]{8,}.*")).firstMatch
        XCTAssertTrue(commit.waitForExistence(timeout: 5), "Build provenance must expose a generated commit SHA value")
#endif
    }

    func testNowPlayingExposesMusicHapticsSubmenu() throws {
        app.launchArguments = ["-auralis-ui-smoke-now-playing"]
        app.launch()

        XCTAssertTrue(app.staticTexts["正在播放"].waitForExistence(timeout: 15), "Now Playing sheet did not open from the deterministic smoke-test route")
        let more = app.buttons["auralis.nowPlaying.moreActions"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 10), "Now Playing more-actions entry is missing")
        more.tap()

        let hapticsMenu = app.descendants(matching: .any)["auralis.nowPlaying.musicHaptics"].firstMatch
        XCTAssertTrue(hapticsMenu.waitForExistence(timeout: 10), "Music Haptics submenu entry is missing from Now Playing")
        hapticsMenu.tap()

        for label in ["跟随全局设置", "为此歌曲开启", "为此歌曲关闭"] {
            XCTAssertTrue(app.buttons[label].waitForExistence(timeout: 5), "Missing Music Haptics option: \(label)")
        }
    }
}
