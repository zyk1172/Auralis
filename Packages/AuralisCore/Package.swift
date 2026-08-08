// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AuralisCore",
    defaultLocalization: "zh-Hans",
    platforms: [
        .iOS("26.0"),
        .macOS(.v15),
    ],
    products: [
        .library(name: "AppShell", targets: ["AppShell"]),
        .library(name: "Domain", targets: ["Domain"]),
        .library(name: "LocalCatalog", targets: ["LocalCatalog"]),
    ],
    targets: [
        .target(name: "Domain"),
        .target(name: "DesignSystem"),
        .target(name: "ThemeEngine", dependencies: ["DesignSystem"]),
        .target(name: "SecurityKit"),
        .target(name: "Observability"),
        .target(name: "OpenSubsonicKit", dependencies: ["Domain", "SecurityKit"]),
        .target(name: "MusicLibrary", dependencies: ["Domain"]),
        .target(name: "PlaybackQueue", dependencies: ["Domain"]),
        .target(name: "PlaybackEngine", dependencies: ["Domain", "PlaybackQueue", "Observability"]),
        .target(name: "OfflineManager", dependencies: ["Domain"]),
        .target(name: "ImagePipeline", dependencies: ["Domain"]),
        .target(name: "LyricsKit", dependencies: ["Domain"]),
        .target(name: "MetadataKit", dependencies: ["Domain"]),
        .target(name: "AIKit", dependencies: ["Domain", "SecurityKit"]),
        .target(name: "RecommendationEngine", dependencies: ["Domain"]),
        .target(name: "Persistence", dependencies: ["Domain"]),
        .target(name: "SystemMediaIntegration", dependencies: ["Domain", "Observability"]),
        .target(name: "LocalCatalog", dependencies: ["Domain", "MusicLibrary"]),
        .target(name: "AgentKit", dependencies: ["Domain", "AIKit", "LocalCatalog"]),
        .target(name: "TestSupport", dependencies: ["Domain"]),
        .target(
            name: "Application",
            dependencies: [
                "Domain", "OpenSubsonicKit", "MusicLibrary", "Persistence",
                "SecurityKit", "Observability", "LocalCatalog",
            ]
        ),
        .target(
            name: "AppShell",
            dependencies: [
                "Application", "Domain", "DesignSystem", "ThemeEngine", "MusicLibrary",
                "PlaybackEngine", "PlaybackQueue", "OfflineManager", "LyricsKit", "ImagePipeline",
                "MetadataKit", "AIKit", "RecommendationEngine", "Observability",
                "SecurityKit", "SystemMediaIntegration", "LocalCatalog", "AgentKit",
            ]
        ),
        .testTarget(name: "DomainTests", dependencies: ["Domain", "TestSupport"]),
        .testTarget(name: "OpenSubsonicKitTests", dependencies: ["OpenSubsonicKit", "Domain"]),
        .testTarget(name: "PlaybackQueueTests", dependencies: ["PlaybackQueue", "Domain", "TestSupport"]),
        .testTarget(name: "MetadataKitTests", dependencies: ["MetadataKit", "Domain", "TestSupport"]),
        .testTarget(name: "AIKitTests", dependencies: ["AIKit"]),
        .testTarget(name: "RecommendationEngineTests", dependencies: ["RecommendationEngine", "Domain", "TestSupport"]),
        .testTarget(name: "OfflineManagerTests", dependencies: ["OfflineManager", "Domain"]),
        .testTarget(name: "SecurityKitTests", dependencies: ["SecurityKit"]),
        .testTarget(name: "PersistenceTests", dependencies: ["Persistence", "Domain"]),
        .testTarget(name: "MusicLibraryTests", dependencies: ["MusicLibrary", "Domain"]),
        .testTarget(
            name: "ApplicationTests",
            dependencies: [
                "Application", "Domain", "OpenSubsonicKit", "MusicLibrary", "Persistence", "SecurityKit",
            ]
        ),
        .testTarget(name: "ObservabilityTests", dependencies: ["Observability"]),
        .testTarget(name: "AppShellTests", dependencies: ["AppShell", "Application", "Domain", "TestSupport", "AgentKit", "LocalCatalog", "AIKit"]),
        .testTarget(
            name: "SystemMediaIntegrationTests",
            dependencies: ["SystemMediaIntegration", "Domain"]
        ),
        .testTarget(name: "LocalCatalogTests", dependencies: ["LocalCatalog", "Domain", "TestSupport"]),
        .testTarget(
            name: "AgentKitTests",
            dependencies: ["AgentKit", "Domain", "LocalCatalog", "TestSupport", "AIKit"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
