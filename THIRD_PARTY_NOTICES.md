# Third-party notices

This inventory covers direct dependencies declared in the current repository. Transitive
artifacts may carry additional notices; the package metadata and upstream license files remain
authoritative. The table is an engineering compatibility review, not legal advice.

## Platform and development dependencies

| Dependency | Version | Source | License / attribution | Usage and distribution risk |
| --- | --- | --- | --- | --- |
| Apple iOS/macOS SDKs (AVFoundation, MediaPlayer, AppIntents, SwiftUI, Security, WidgetKit) | Xcode 27 / platform SDKs required by `project.yml` | [Apple Developer](https://developer.apple.com/) | Apple SDK terms; not project-owned open-source code | Platform APIs used by the app; do not copy or redistribute SDK source. App distribution remains subject to Apple's platform and store terms. |
| XcodeGen | 2.46.0 | [github.com/yonaskolb/XcodeGen](https://github.com/yonaskolb/XcodeGen) | MIT; retain upstream notice when redistributing the tool | Development-only generator; not embedded in the app. CI downloads the pinned release and verifies its SHA-256. |
| Gradle Wrapper | 8.9 | [gradle.org](https://gradle.org/) | Apache-2.0; wrapper files retain upstream headers | Build tool only; not an Auralis runtime dependency. |
| Android Gradle Plugin | 8.5.2 | [developer.android.com/studio/build](https://developer.android.com/build) | Apache-2.0 | Build tool; compatible with GPLv3 source distribution when its notice is retained. |
| Kotlin, KSP, Kotlin Compose and Kotlin serialization plugins | Kotlin 2.0.21; KSP 2.0.21-1.0.27 | [kotlinlang.org](https://kotlinlang.org/) and [KSP](https://github.com/google/ksp) | Apache-2.0 | Build/compiler plugins and generated code support; not a private repository dependency. |

## Android runtime and test dependencies

| Dependency family | Versions declared in `android/gradle/libs.versions.toml` | Source | License / attribution | Usage and distribution risk |
| --- | --- | --- | --- | --- |
| AndroidX Core, Activity, Lifecycle, Navigation, Compose, Media3, Room, DataStore, Security, and AndroidX test libraries | Core 1.13.1; Activity 1.9.1; Lifecycle 2.8.6; Navigation 2.8.3; Compose BOM 2024.09.03; Media3 1.4.1; Room 2.6.1; DataStore 1.1.1; Security 1.1.0-alpha06; Test Core 1.6.1; Test Ext JUnit 1.2.1 | [AndroidX](https://developer.android.com/jetpack) | Apache-2.0 | Runtime and test libraries. Apache-2.0 is compatible with GPLv3; preserve the upstream notice and license for redistributed binaries. |
| OkHttp and MockWebServer | 4.12.0 | [square.github.io/okhttp](https://square.github.io/okhttp/) | Apache-2.0 | Runtime HTTP client and test server; compatible with GPLv3 with notices retained. |
| Retrofit and Kotlin serialization converter | Retrofit 2.11.0; converter 1.0.0 | [square.github.io/retrofit](https://square.github.io/retrofit/) | Apache-2.0 | Runtime API client and serialization adapter; compatible with GPLv3 with notices retained. |
| kotlinx.coroutines and kotlinx.serialization | 1.8.1 and 1.7.1 | [github.com/Kotlin/kotlinx.coroutines](https://github.com/Kotlin/kotlinx.coroutines), [github.com/Kotlin/kotlinx.serialization](https://github.com/Kotlin/kotlinx.serialization) | Apache-2.0 | Runtime concurrency and JSON serialization; compatible with GPLv3 with notices retained. |
| Coil | 2.6.0 | [coil-kt.github.io/coil](https://coil-kt.github.io/coil/) | Apache-2.0 | Android image loading; compatible with GPLv3 with notices retained. |
| Truth and Turbine | Truth 1.4.4; Turbine 1.1.0 | [Truth](https://truth.dev/), [Turbine](https://github.com/cashapp/turbine) | Apache-2.0 | Test-only assertions and Flow testing; not shipped in the application. |
| JUnit 4 | 4.13.2 | [junit.org/junit4](https://github.com/junit-team/junit4) | EPL-1.0 | Test-only dependency; not linked into the app runtime. Keep its license with test distributions. |
| Robolectric | 4.12.2 | [robolectric.org](https://robolectric.org/) | MIT | Test-only Android environment; not shipped in the application. |

All versions above are direct declarations observed in the repository at audit time. A lockfile or
resolved dependency report should be reviewed again before a release. No CocoaPods, Carthage,
external SwiftPM package, vendored XCFramework, or copied third-party source was found in the
current build graph.

## Project test content and external services

- `Packages/AuralisCore/Tests/MusicHapticsTests/RemoteFLACFixture.swift` is a short project test
  fixture with no album artwork or identifying music metadata. It is not a commercial music
  sample and must not be replaced with one.
- OpenSubsonic/Navidrome, AI providers, and remote artwork/lyrics are external protocols, services,
  or data sources. Their names and APIs do not grant rights to redistribute their content.
- Auralis app icons, logos, and official visual assets are project brand assets, not third-party
  dependency material. Their relationship to the GPL source license is described in
  [`TRADEMARKS.md`](TRADEMARKS.md).
