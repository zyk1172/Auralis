import AIKit
import Foundation
import Testing

@Test("SSE parser handles split chunks and multiline data")
func splitSSEChunks() {
    var parser = SSEParser()
    let first = parser.append(Data("event: message\ndata: {\"delta\":\"深".utf8))
    #expect(first.isEmpty)
    let second = parser.append(Data("夜\"}\ndata: second-line\n\n".utf8))
    #expect(second == [.init(event: "message", data: "{\"delta\":\"深夜\"}\nsecond-line")])
}

@Test("SSE data value keeps trailing space and only strips one leading separator space")
func sseFieldValueSpacing() {
    // 尾部空格属于 payload，必须保留
    var trailing = SSEParser()
    #expect(trailing.append(Data("data: hello \n\n".utf8)) == [.init(data: "hello ")])
    // 冒号后只移除一个分隔空格，第二个空格属于 payload
    var doubleLeading = SSEParser()
    #expect(doubleLeading.append(Data("data:  hello\n\n".utf8)) == [.init(data: " hello")])
    // 无前导空格时不裁剪
    var plain = SSEParser()
    #expect(plain.append(Data("data:hello\n\n".utf8)) == [.init(data: "hello")])
}

@Test("Mock provider stream completes and can be consumed asynchronously")
func mockProviderStream() async throws {
    let provider = MockAIProvider()
    let request = AICompletionRequest(model: "test-model", messages: [.init(role: .user, content: "深夜音乐")])
    var events: [AIStreamEvent] = []
    for try await event in provider.stream(request) { events.append(event) }
    #expect(events.first == .started(model: "test-model"))
    #expect(events.last == .completed)
}
