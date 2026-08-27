import AIKit
import Foundation
import SecurityKit
import Testing

@Test("Non-sensitive literal headers survive a Codable round trip")
func literalHeaderRoundTrip() throws {
    let headers = try AIProviderHeaders([
        "X-Auralis-Client": .literal("desktop-fixture"),
    ])
    let configuration = AIProviderConfiguration(
        name: "Fixture Provider",
        baseURL: try #require(URL(string: "https://ai.example.test")),
        model: "fixture-model",
        customHeaders: headers
    )

    let encoded = try JSONEncoder().encode(configuration)
    let decoded = try JSONDecoder().decode(AIProviderConfiguration.self, from: encoded)
    #expect(decoded == configuration)
    #expect(decoded.customHeaders["x-auralis-client"] == .literal("desktop-fixture"))
}

@Test("Sensitive header names reject literal values", arguments: [
    "Authorization",
    "Proxy-Authorization",
    "X-API-Key",
    "api_key",
    "OpenAI-API-Key",
    "X-Auth-Token",
    "X-Access-Token",
    "X-Token",
    "X-Client-Secret",
    "X-Credential-ID",
    "Cookie",
])
func sensitiveLiteralHeaderIsRejected(name: String) {
    #expect(throws: AIProviderHeaderError.sensitiveHeaderRequiresCredential(name)) {
        _ = try AIProviderHeaders([name: .literal("synthetic-value")])
    }
}

@Test("Sensitive headers accept only a credential reference")
func sensitiveCredentialHeaderIsAccepted() throws {
    let credentialID = CredentialID(rawValue: "ai-header.fixture")
    let headers = try AIProviderHeaders([
        "Authorization": .credential(credentialID),
    ])
    let encoded = try JSONEncoder().encode(headers)
    let decoded = try JSONDecoder().decode(AIProviderHeaders.self, from: encoded)

    #expect(decoded["authorization"] == .credential(credentialID))
    #expect(!String(decoding: encoded, as: UTF8.self).contains("synthetic-private-value"))
}

@Test("Crafted Codable data cannot inject a literal sensitive header")
func decodingRejectsSensitiveLiteral() throws {
    let encoded = try #require(
        #"{"Authorization":{"kind":"literal","value":"synthetic-value"}}"#.data(using: .utf8)
    )

    #expect(throws: AIProviderHeaderError.sensitiveHeaderRequiresCredential("Authorization")) {
        _ = try JSONDecoder().decode(AIProviderHeaders.self, from: encoded)
    }
}

@Test("Header names and literal values reject response-splitting characters")
func rejectsHeaderInjection() {
    #expect(throws: AIProviderHeaderError.invalidName("X-Test\r\nInjected")) {
        _ = try AIProviderHeaders(["X-Test\r\nInjected": .literal("fixture")])
    }
    #expect(throws: AIProviderHeaderError.invalidLiteralValue(header: "X-Test")) {
        _ = try AIProviderHeaders(["X-Test": .literal("fixture\r\nInjected: value")])
    }
}

@Test("ModelCapabilities 不再把输出限制为上下文的一半")
func modelCapabilitiesPreserveConfiguredOutputLimit() {
    let capabilities = ModelCapabilities(
        maxContextTokens: 128_000,
        maxOutputTokens: 100_000,
        supportsToolCalling: true
    )

    #expect(
        capabilities.maxContextTokens
            == 128_000
    )

    #expect(
        capabilities.maxOutputTokens
            == 100_000
    )
}

@Test("ModelCapabilities 支持百万级自定义上下文")
func modelCapabilitiesPreserveLargeContextLimit() {
    let capabilities = ModelCapabilities(
        maxContextTokens: 2_000_000,
        maxOutputTokens: 200_000
    )

    #expect(
        capabilities.maxContextTokens
            == 2_000_000
    )

    #expect(
        capabilities.maxOutputTokens
            == 200_000
    )
}

@Test("Reasoning configuration round trips and old completion requests remain decodable")
func reasoningConfigurationIsProviderNeutralAndBackwardCompatible() throws {
    for effort in AIReasoningEffort.allCases {
        for mode in AIReasoningMode.allCases {
            let configuration = AIReasoningConfiguration(mode: mode, effort: effort)
            let decoded = try JSONDecoder().decode(
                AIReasoningConfiguration.self,
                from: JSONEncoder().encode(configuration)
            )
            #expect(decoded == configuration)
        }
    }

    let oldEnabled = try #require(#"{"enabled":true,"effort":"high"}"#.data(using: .utf8))
    let oldDisabled = try #require(#"{"enabled":false,"effort":"low"}"#.data(using: .utf8))
    #expect(try JSONDecoder().decode(AIReasoningConfiguration.self, from: oldEnabled).mode == .enabled)
    #expect(try JSONDecoder().decode(AIReasoningConfiguration.self, from: oldDisabled).mode == .disabled)

    let automatic = AIReasoningConfiguration(mode: .automatic, effort: .max)
    #expect(automatic.enabled == false)
    var projected = automatic
    projected.enabled = true
    #expect(projected.mode == .enabled)

    let oldRequest = AICompletionRequest(
        model: "legacy-model",
        messages: [AIMessage(role: .user, content: "hello")],
        maxTokens: 32
    )
    let decodedOldRequest = try JSONDecoder().decode(
        AICompletionRequest.self,
        from: JSONEncoder().encode(oldRequest)
    )
    #expect(decodedOldRequest.reasoning == nil)
}

@Test("Legacy reasoning bool remains an explicit disabled request")
func legacyDisabledReasoningMapsToDisabledMode() throws {
    let configuration = AIReasoningConfiguration(enabled: false, effort: .high)
    #expect(configuration.mode == .disabled)
    #expect(configuration.enabled == false)
    let decoded = try JSONDecoder().decode(
        AIReasoningConfiguration.self,
        from: JSONEncoder().encode(configuration)
    )
    #expect(decoded.mode == .disabled)
    #expect(decoded.effort == .high)
}
