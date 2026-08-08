import Domain
import Foundation
import OpenSubsonicKit
import SecurityKit
import Testing

@Test("Token authentication matches the OpenSubsonic reference vector")
func tokenReferenceVector() {
    #expect(
        OpenSubsonicTokenSigner.token(password: "sesame", salt: "c19b2d")
            == "26719a1196d2a940705a59634eb18eab"
    )
}

@Test("Token credentials become a salted form POST and never send the password")
func tokenRequest() async throws {
    let vault = InMemoryCredentialVault()
    let credentialID = CredentialID(rawValue: "password")
    try await vault.store("sesame", for: credentialID)
    let client = OpenSubsonicClient(
        configuration: OpenSubsonicConfiguration(
            serverID: "test-server",
            baseURL: try #require(URL(string: "https://music.example.test/navidrome/")),
            authentication: .token(username: "joe+listener", credentialID: credentialID)
        ),
        credentialVault: vault,
        session: makeMockSession(),
        retryPolicy: .disabled,
        saltGenerator: { "c19b2d" }
    )

    let request = try await client.makeURLRequest(
        for: OpenSubsonicRequestFactory.descriptor(.search3, parameters: ["query": "night & rain"])
    )
    let values = formValues(from: request)

    #expect(request.httpMethod == "POST")
    #expect(request.url?.absoluteString == "https://music.example.test/navidrome/rest/search3.view")
    #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded; charset=utf-8")
    #expect(values["u"] == ["joe+listener"])
    #expect(values["s"] == ["c19b2d"])
    #expect(values["t"] == ["26719a1196d2a940705a59634eb18eab"])
    #expect(values["query"] == ["night & rain"])
    #expect(values["c"] == ["Auralis"])
    #expect(values["v"] == ["1.16.1"])
    #expect(values["f"] == ["json"])
    #expect(values["p"] == nil)
}

@Test("API key authentication omits username and token fields")
func apiKeyRequest() async throws {
    let vault = InMemoryCredentialVault()
    let credentialID = CredentialID(rawValue: "api-key")
    try await vault.store("test-api-key", for: credentialID)
    let client = OpenSubsonicClient(
        configuration: OpenSubsonicConfiguration(
            baseURL: try #require(URL(string: "https://music.example.test")),
            authentication: .apiKey(credentialID: credentialID)
        ),
        credentialVault: vault,
        session: makeMockSession(),
        retryPolicy: .disabled
    )

    let request = try await client.makeURLRequest(
        for: OpenSubsonicRequestFactory.descriptor(.ping)
    )
    let values = formValues(from: request)
    #expect(values["apiKey"] == ["test-api-key"])
    #expect(values["u"] == nil)
    #expect(values["t"] == nil)
    #expect(values["s"] == nil)
}

@Test("Callers cannot inject a second authentication mechanism")
func rejectsAuthenticationInjection() async throws {
    let vault = InMemoryCredentialVault()
    let credentialID = CredentialID(rawValue: "password")
    try await vault.store("test-password", for: credentialID)
    let client = OpenSubsonicClient(
        configuration: OpenSubsonicConfiguration(
            baseURL: try #require(URL(string: "https://music.example.test")),
            authentication: .token(username: "tester", credentialID: credentialID)
        ),
        credentialVault: vault,
        retryPolicy: .disabled,
        saltGenerator: { "abcdef" }
    )

    await #expect(throws: OpenSubsonicClientError.invalidParameter("authentication")) {
        _ = try await client.makeURLRequest(
            for: .init(endpoint: .ping, parameters: ["apiKey": "injected"])
        )
    }
}
