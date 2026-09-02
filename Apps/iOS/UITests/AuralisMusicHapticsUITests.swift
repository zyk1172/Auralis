import CoreGraphics
import XCTest

@MainActor
final class AuralisMusicHapticsUITests: XCTestCase {
    private let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
        app.terminate()
    }

    private func launchSmokeApp(with arguments: String...) {
        app.launchArguments = [
            "-AppleLanguages", "(zh-Hans)",
            "-AppleLocale", "zh_CN",
        ] + arguments
        app.launch()
    }

    func testPlaybackSettingsAlwaysExposeMusicHaptics() throws {
        launchSmokeApp(with: "-auralis-ui-smoke")

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

    func testNowPlayingExposesMusicHapticsToggle() throws {
        launchSmokeApp(with: "-auralis-ui-smoke-now-playing")

        XCTAssertTrue(app.staticTexts["正在播放"].waitForExistence(timeout: 15), "Now Playing sheet did not open from the deterministic smoke-test route")
        let more = app.buttons["auralis.nowPlaying.moreActions"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 10), "Now Playing more-actions entry is missing")
        more.tap()

        // SwiftUI renders a Menu Toggle as a menu control rather than an
        // XCUIElementTypeSwitch on some iOS versions.  The stable identifier
        // is the contract; keep the query type-agnostic across those renderers.
        let hapticsToggle = app.descendants(matching: .any)["auralis.nowPlaying.musicHaptics"].firstMatch
        XCTAssertTrue(
            hapticsToggle.waitForExistence(timeout: 10),
            "Now Playing must expose Music Haptics as a direct single-level toggle"
        )

        // The playback page intentionally no longer exposes the old
        // inherit/enabled/disabled submenu.  Keep this assertion aligned with
        // the product contract so a future UI change cannot silently restore
        // the two-step interaction.
        XCTAssertFalse(
            app.buttons["跟随全局设置"].waitForExistence(timeout: 1),
            "The old Music Haptics submenu must not be restored"
        )
    }

    func testAssistantSessionSheetSurvivesColdBootstrap() throws {
        launchSmokeApp(with: "-auralis-ui-smoke-assistant")

        let assistant = app.buttons["AI 助手"].firstMatch
        XCTAssertTrue(assistant.waitForExistence(timeout: 15), "Assistant entry point is missing")
        assistant.tap()

        let sessions = app.buttons["会话列表"].firstMatch
        XCTAssertTrue(sessions.waitForExistence(timeout: 10), "Assistant did not expose the session button")
        sessions.tap()

        let title = app.staticTexts["会话"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 10), "Session sheet did not present")
        Thread.sleep(forTimeInterval: 2)
        XCTAssertTrue(title.exists, "Session sheet must survive delayed launch bootstrap")
    }

    func testHomeCollapsedDockDoesNotHitExpandedPlayerRegion() throws {
        assertCollapsedDockHitTesting(with: "-auralis-ui-smoke-dock-home")
    }

    func testLibraryCollapsedDockDoesNotHitExpandedPlayerRegion() throws {
        assertCollapsedDockHitTesting(with: "-auralis-ui-smoke-dock-library")
    }

    func testHomeCompactDockLeavesLibrarySummaryAboveDock() throws {
        launchSmokeApp(with: "-auralis-ui-smoke-dock-clearance-home")

        let scrollView = app.scrollViews.firstMatch
        XCTAssertTrue(scrollView.waitForExistence(timeout: 15), "Home must expose its real ScrollView")
        scrollToBottom(scrollView)

        assertBottomContentIsAboveDock(
            contentIdentifier: "auralis.home.librarySummary",
            dockIdentifier: "auralis.dock.compact",
            description: "Home library summary must remain above the compact Dock"
        )
    }

    func testLibraryCompactDockLeavesLastTrackAboveDock() throws {
        launchSmokeApp(with: "-auralis-ui-smoke-dock-clearance-library")

        let tracksScope = app.buttons["歌曲"].firstMatch
        XCTAssertTrue(tracksScope.waitForExistence(timeout: 15), "Library must expose the songs scope")
        tracksScope.tap()

        let table = app.tables.firstMatch
        XCTAssertTrue(table.waitForExistence(timeout: 15), "Library songs must be rendered by a List")
        scrollToBottom(table)

        let lastTrack = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS[c] %@", "Dock clearance track 36")
        ).firstMatch
        XCTAssertTrue(lastTrack.waitForExistence(timeout: 10), "The deterministic last library track must be visible")

        assertBottomContentIsAboveDock(
            content: lastTrack,
            dockIdentifier: "auralis.dock.compact",
            description: "The last library track must remain above the compact Dock"
        )
    }

    private func assertCollapsedDockHitTesting(with smokeArgument: String) {
        launchSmokeApp(with: smokeArgument)

        let compactPlayer = app.descendants(matching: .any)["auralis.dock.compactPlayer"].firstMatch
        XCTAssertTrue(
            compactPlayer.waitForExistence(timeout: 15),
            "Collapsed Dock must expose the real compact player interaction element"
        )

        // On the iPhone target the expanded player center is about 98pt above
        // the bottom edge (126pt container, 28pt player center). This coordinate
        // is intentionally outside the 62pt terminal Dock.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.88)).tap()
        XCTAssertFalse(
            app.staticTexts["正在播放"].waitForExistence(timeout: 1),
            "The old expanded player region must not open Now Playing after collapse"
        )

        compactPlayer.tap()
        XCTAssertTrue(
            app.staticTexts["正在播放"].waitForExistence(timeout: 10),
            "The real compact player capsule must still open Now Playing"
        )
    }

    private func scrollToBottom(_ container: XCUIElement) {
        for _ in 0..<10 {
            container.swipeUp()
        }
    }

    private func assertBottomContentIsAboveDock(
        contentIdentifier: String,
        dockIdentifier: String,
        description: String
    ) {
        let content = app.descendants(matching: .any)[contentIdentifier].firstMatch
        XCTAssertTrue(content.waitForExistence(timeout: 10), "Missing \(contentIdentifier)")
        assertBottomContentIsAboveDock(content: content, dockIdentifier: dockIdentifier, description: description)
    }

    private func assertBottomContentIsAboveDock(
        content: XCUIElement,
        dockIdentifier: String,
        description: String
    ) {
        let dock = app.descendants(matching: .any)[dockIdentifier].firstMatch
        XCTAssertTrue(dock.waitForExistence(timeout: 10), "Missing \(dockIdentifier)")
        XCTAssertFalse(content.frame.isEmpty, "\(description): content frame must be measurable")
        XCTAssertFalse(dock.frame.isEmpty, "\(description): Dock frame must be measurable")
        XCTAssertLessThanOrEqual(
            content.frame.maxY,
            dock.frame.minY + 1,
            description
        )
    }
}
