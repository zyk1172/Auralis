import Foundation

public struct SSEMessage: Equatable, Sendable {
    public var event: String?
    public var id: String?
    public var data: String
    public init(event: String? = nil, id: String? = nil, data: String) {
        self.event = event
        self.id = id
        self.data = data
    }
}

public struct SSEParser: Sendable {
    private var buffer = ""
    public init() {}

    public mutating func append(_ data: Data) -> [SSEMessage] {
        buffer += String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
        var messages: [SSEMessage] = []
        while let range = buffer.range(of: "\n\n") {
            let raw = String(buffer[..<range.lowerBound])
            buffer.removeSubrange(buffer.startIndex..<range.upperBound)
            if let message = parseBlock(raw) { messages.append(message) }
        }
        return messages
    }

    public mutating func finish() -> [SSEMessage] {
        defer { buffer = "" }
        guard let message = parseBlock(buffer) else { return [] }
        return [message]
    }

    private func parseBlock(_ block: String) -> SSEMessage? {
        var event: String?
        var id: String?
        var dataLines: [String] = []
        for line in block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix(":") { continue }
            let pieces = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            let field = String(pieces[0])
            let value = pieces.count > 1 ? Self.fieldValue(pieces[1]) : ""
            switch field {
            case "event": event = value
            case "id": id = value
            case "data": dataLines.append(value)
            default: break
            }
        }
        guard !dataLines.isEmpty else { return nil }
        return SSEMessage(event: event, id: id, data: dataLines.joined(separator: "\n"))
    }

    /// SSE 字段值（WHATWG）：冒号后如果紧跟一个空格，仅移除这一个分隔空格；
    /// 其余前导空格与全部尾部空格都属于 payload，不得裁剪。
    private static func fieldValue(_ raw: Substring) -> String {
        var value = raw
        if value.first == " " {
            value.removeFirst()
        }
        return String(value)
    }
}
