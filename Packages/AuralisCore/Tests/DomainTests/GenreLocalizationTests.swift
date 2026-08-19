import Testing
import Foundation
@testable import Domain

@Suite("Genre Localization")
struct GenreLocalizationTests {
    @Test("Known genres have display names")
    func knownGenres() {
        #expect(GenreLocalization.displayName(for: "rock") == "摇滚" || GenreLocalization.displayName(for: "rock") == "Rock" || GenreLocalization.displayName(for: "rock") == "搖滾")
        #expect(GenreLocalization.displayName(for: "Rock") == GenreLocalization.displayName(for: "rock"))
        #expect(GenreLocalization.displayName(for: "ROCK") == GenreLocalization.displayName(for: "rock"))
    }

    @Test("Hip hop aliases normalize to same display name")
    func hipHopAliases() {
        let a = GenreLocalization.displayName(for: "hip hop")
        let b = GenreLocalization.displayName(for: "hip-hop")
        let c = GenreLocalization.displayName(for: "Hip Hop")
        #expect(a == b)
        #expect(b == c)
    }

    @Test("R&B aliases normalize")
    func rnbAliases() {
        let a = GenreLocalization.displayName(for: "r&b")
        let b = GenreLocalization.displayName(for: "rnb")
        let c = GenreLocalization.displayName(for: "R&B")
        #expect(a == b)
        #expect(b == c)
    }

    @Test("Unknown genre returns original")
    func unknownGenre() {
        let unknown = "Neo Psychedelia XYZ"
        #expect(GenreLocalization.displayName(for: unknown) == unknown)
        #expect(GenreLocalization.displayName(for: unknown.lowercased()) == unknown.lowercased())
        // Empty and whitespace
        #expect(GenreLocalization.displayName(for: "") == "")
        #expect(GenreLocalization.displayName(for: "  ") == "  ")
    }

    @Test("Catalog contains all expected genre keys")
    func catalogCompleteness() {
        // Load the Domain catalog via file path relative to this test file (robust for both local and CI)
        let thisFile = URL(fileURLWithPath: #file)
        let packageRoot = thisFile
            .deletingLastPathComponent() // DomainTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // AuralisCore
            .deletingLastPathComponent() // Packages
        let catalogURL = packageRoot
            .appendingPathComponent("Packages/AuralisCore/Sources/Domain/Resources/Localizable.xcstrings")
        var catalogPath: String? = catalogURL.path
        if !FileManager.default.fileExists(atPath: catalogPath!) {
            catalogPath = Bundle.module.path(forResource: "Localizable", ofType: "xcstrings")
        }
        guard let path = catalogPath, FileManager.default.fileExists(atPath: path) else {
            Issue.record("Domain catalog not found at \(String(describing: catalogPath))")
            return
        }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let strings = json["strings"] as? [String: Any] else {
            Issue.record("Failed to load Domain catalog at \(path)")
            return
        }
        let expected = ["genre.rock", "genre.pop", "genre.jazz", "genre.hip_hop", "genre.rnb", "genre.mandopop", "genre.k_pop"]
        for key in expected {
            #expect(strings[key] != nil, "Missing genre key \(key)")
        }
        // Check a few have en and zh-Hant
        for key in ["genre.rock", "genre.pop"] {
            if let entry = strings[key] as? [String: Any],
               let locs = entry["localizations"] as? [String: Any] {
                #expect(locs["en"] != nil, "Missing en for \(key)")
                #expect(locs["zh-Hant"] != nil, "Missing zh-Hant for \(key)")
            }
        }
    }

    @Test("Display name is consistent for known canonical")
    func canonicalConsistency() {
        // All canonical IDs from the table should have a non-empty display name (not just the raw key)
        let known = ["pop", "rock", "electronic", "hip_hop", "mandopop", "k_pop", "j_pop", "classical", "jazz"]
        for id in known {
            let display = GenreLocalization.displayName(for: id)
            #expect(!display.isEmpty)
            #expect(display != "genre.\(id)", "Display name for \(id) should not be the raw key")
        }
    }
}
