// SPDX-License-Identifier: GPL-3.0-only
@testable import AIKit
import Foundation
import Testing

@Suite("Native continuation scope and ordering")
struct NativeContinuationTests {
    @Test func anthropicReplaysWholeTurnAfterUserAndPreservesOrder() throws {
        let native = try AIJSONValue(jsonData: Data(#"[{"type":"text","text":"first"},{"type":"thinking","thinking":"private","signature":"sig"},{"type":"redacted_thinking","data":"opaque"},{"type":"tool_use","id":"c","name":"read","input":{}}]"#.utf8))
        let scope = "endpoint|model"
        let transcript = AITranscript(items: [
            .userText("question"),
            .providerContinuation(.init(vendor: .anthropicMessages, ordinal: 0, payload: native, originScope: scope)),
            .assistantToolCalls(text: "first", calls: [.init(id: "c", name: "read", arguments: "{}")]),
            .toolResult(.init(callID: "c", toolName: "read", content: "done")),
        ])
        let wire = AnthropicMessagesProvider.encodeMessages(transcript, scope: scope)
        let content = try #require(wire[1]["content"] as? [[String: Any]])
        #expect(content.compactMap { $0["type"] as? String } == ["text", "thinking", "redacted_thinking", "tool_use"])
        #expect(content[1]["signature"] as? String == "sig")
        let switched = AnthropicMessagesProvider.encodeMessages(transcript, scope: "other")
        let ordinary = try #require(switched[1]["content"] as? [[String: Any]])
        #expect(ordinary.compactMap { $0["type"] as? String } == ["text", "tool_use"])
    }

    @Test func responsesCapturesAllOutputItems() throws {
        let output: [[String: Any]] = [
            ["type": "message", "id": "m", "role": "assistant", "content": []],
            ["type": "reasoning", "id": "r", "encrypted_content": "opaque", "summary": []],
            ["type": "function_call", "call_id": "c", "name": "read", "arguments": "{}"],
        ]
        let captured = try #require(OpenAICompatibleProvider.responsesContinuations(from: ["output": output])?.first)
        guard case let .array(items) = captured.payload else { Issue.record("Missing full native output"); return }
        #expect(items.count == 3)
        #expect(captured.bound(to: "scope").originScope == "scope")
    }

    @Test func manualThinkingHonorsBudgetAndForcedChoice() {
        let reasoning = AIReasoningConfiguration(enabled: true, effort: .low)
        #expect(AnthropicMessagesProvider.encodeThinking(reasoning, maxTokens: 1_024, supportsReasoningControl: true, dialect: .manual, toolChoice: nil) == nil)
        #expect(AnthropicMessagesProvider.encodeThinking(reasoning, maxTokens: 2_048, supportsReasoningControl: true, dialect: .manual, toolChoice: .required) == nil)
        #expect(AnthropicMessagesProvider.encodeThinking(reasoning, maxTokens: 2_048, supportsReasoningControl: true, dialect: .adaptive, toolChoice: .required)?["type"] as? String == "adaptive")
    }
}
