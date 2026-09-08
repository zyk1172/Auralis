// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing

@testable import AIKit

struct AITranscriptTests {
    @Test("Provider-neutral transcript preserves tool identity and structured arguments")
    func preservesToolConversation() throws {
        let call = AIToolCall(
            id: "call-1",
            name: "queue_append",
            arguments: .object(["trackIDs": .array([.string("navidrome:1")])])
        )
        let transcript = AITranscript(messages: [
            AIMessage(role: .system, content: "system"),
            AIMessage(role: .user, content: "把它加入队列"),
            AIMessage(role: .assistant, content: "", toolCalls: [call]),
            AIMessage(role: .tool, content: "已加入", toolCallID: "call-1", name: "queue_append"),
        ])

        #expect(transcript.items.count == 4)
        #expect(call.structuredArguments == .object(["trackIDs": .array([.string("navidrome:1")])]))
        #expect(transcript.messages[2].toolCalls?.first?.id == "call-1")
        #expect(transcript.messages[3].toolCallID == "call-1")

        let encoded = try JSONEncoder().encode(transcript)
        let decoded = try JSONDecoder().decode(AITranscript.self, from: encoded)
        #expect(decoded == transcript)
    }

    @Test("AICompletionRequest exposes the same transcript to compatibility providers")
    func requestUsesTranscriptProjection() {
        let transcript = AITranscript(items: [.userText("hello"), .reasoning("internal")])
        let request = AICompletionRequest(model: "fixture", transcript: transcript)
        #expect(request.transcript == transcript)
        #expect(request.messages.map(\.content) == ["hello"])
    }
}
