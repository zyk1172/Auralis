import Domain
import Foundation
import OpenSubsonicKit
import SecurityKit
import Testing

@Test("Capability Registry is driven by advertised extensions")
func advertisedCapabilities() {
    let capabilities = CapabilityRegistry.capabilities(from: [
        .init(name: "songLyrics", versions: [1]),
        .init(name: "sonicSimilarity", versions: [1]),
        .init(name: "indexBasedQueue", versions: [1]),
        .init(name: "playbackReport", versions: [1]),
        .init(name: "transcoding", versions: [1]),
        .init(name: "transcodeOffset", versions: [1]),
        .init(name: "apiKeyAuthentication", versions: [1]),
    ])
    #expect(capabilities.supportsStructuredLyrics)
    #expect(capabilities.supportsSonicSimilarity)
    #expect(capabilities.supportsIndexedQueue)
    #expect(capabilities.supportsPlaybackReport)
    #expect(capabilities.supportsTranscoding)
    #expect(capabilities.supportsTranscodeOffset)
    #expect(capabilities.supportsAPIKeyAuthentication)
}

@Test("Unknown servers do not get optimistic capabilities")
func noOptimisticCapabilities() {
    #expect(CapabilityRegistry.capabilities(from: []) == ServerCapabilities())
}

@Test("Endpoint URL preserves a server path prefix")
func endpointURL() throws {
    let base = try #require(URL(string: "https://music.example.test/navidrome/"))
    let url = try OpenSubsonicRequestFactory.endpointURL(baseURL: base, endpoint: .ping)
    #expect(url.absoluteString == "https://music.example.test/navidrome/rest/ping.view")
}

@Test("Default server identifiers are stable, normalized, and do not expose the URL")
func opaqueDefaultServerIdentifier() throws {
    let credentialID = CredentialID(rawValue: "fixture-credential")
    let firstURL = try #require(URL(string: "https://Music.Example.Test:443/navidrome/?view=private"))
    let equivalentURL = try #require(URL(string: "https://music.example.test/navidrome"))
    let first = OpenSubsonicConfiguration(
        baseURL: firstURL,
        authentication: .token(username: "fixture-user", credentialID: credentialID)
    )
    let equivalent = OpenSubsonicConfiguration(
        baseURL: equivalentURL,
        authentication: .token(username: "fixture-user", credentialID: credentialID)
    )

    #expect(first.serverID == equivalent.serverID)
    #expect(
        first.serverID.rawValue
            == "opensubsonic-ab8ecca9b46670d50d4cbc7eb2d925f7587a632dc8ab51f9a4a544b28f00742e"
    )
    #expect(first.serverID.rawValue.hasPrefix("opensubsonic-"))
    #expect(first.serverID.rawValue.count == 77)
    #expect(!first.serverID.rawValue.localizedCaseInsensitiveContains("music"))
    #expect(!first.serverID.rawValue.contains("navidrome"))
    #expect(!first.serverID.rawValue.contains(":"))
}

@Test("An explicit server identifier remains source compatible")
func explicitServerIdentifierIsPreserved() throws {
    let explicit: ServerID = "fixture-server"
    let configuration = OpenSubsonicConfiguration(
        serverID: explicit,
        baseURL: try #require(URL(string: "https://music.example.test")),
        authentication: .apiKey(credentialID: CredentialID(rawValue: "fixture-credential"))
    )

    #expect(configuration.serverID == explicit)
}
