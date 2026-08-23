import AIKit
import Domain
import Foundation
import LocalCatalog

/// ToolRuntime 是所有模型工具调用的执行前边界：注册表负责能力和副作用，
/// Runtime 负责参数形状，具体工具负责业务语义与真实状态。
public enum ToolRuntimeError: Error, LocalizedError, Equatable, Sendable {
    case unknownTool(String)
    case missingParameter(String)
    case unknownParameter(String)
    case invalidParameter(name: String, expected: String, value: String)

    public var errorDescription: String? {
        switch self {
        case let .unknownTool(name): "未知工具：\(name)"
        case let .missingParameter(name): "缺少必填参数：\(name)"
        case let .unknownParameter(name): "工具不接受参数：\(name)"
        case let .invalidParameter(name, expected, value): "参数 \(name) 应为 \(expected)，实际为：\(value)"
        }
    }
}

public struct ToolRuntime {
    public init() {}

    public static func execute(
        _ call: ToolCall,
        bridge: AgentBridge,
        catalog: LocalCatalogStore,
        serverID: ServerID?,
        systemService: (any AgentSystemService)?,
        externalMusicService: (any AgentExternalMusicService)? = nil,
        allowsLyrics: Bool = false,
        providerCapabilities: ModelCapabilities? = nil,
        webService: (any AgentWebService)? = nil
    ) async -> ToolResult {
        guard let descriptor = AgentToolRegistry.descriptor(for: call.name) else {
            return ToolResult(
                call: call,
                permission: .readOnly,
                success: false,
                summary: ToolRuntimeError.unknownTool(call.name).localizedDescription
            )
        }

        do {
            try validate(call, descriptor: descriptor)
            return await AgentToolRegistry.execute(
                call,
                bridge: bridge,
                catalog: catalog,
                serverID: serverID,
                systemService: systemService,
                externalMusicService: externalMusicService,
                allowsLyrics: allowsLyrics,
                providerCapabilities: providerCapabilities,
                webService: webService
            )
        } catch {
            return ToolResult(
                call: call,
                permission: descriptor.permission,
                success: false,
                summary: "参数校验失败：\(error.localizedDescription)"
            )
        }
    }

    public static func validate(_ call: ToolCall, descriptor: ToolDescriptor) throws {
        let definitions = Dictionary(uniqueKeysWithValues: descriptor.parameters.map { ($0.name, $0) })
        for name in call.arguments.keys where definitions[name] == nil {
            if call.name == "library_index_v2_write_batch", name == "itemsJSON" { continue }
            throw ToolRuntimeError.unknownParameter(name)
        }
        for parameter in descriptor.parameters where parameter.required {
            let value = call.arguments[parameter.name]
                ?? (call.name == "library_index_v2_write_batch" && parameter.name == "items" ? call.arguments["itemsJSON"] : nil)
            guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ToolRuntimeError.missingParameter(parameter.name)
            }
        }
        for parameter in descriptor.parameters {
            let value = call.arguments[parameter.name]
                ?? (call.name == "library_index_v2_write_batch" && parameter.name == "items" ? call.arguments["itemsJSON"] : nil)
            guard let value, let schemaJSON = parameter.schemaJSON else { continue }
            try validate(value: value, name: parameter.name, schemaJSON: schemaJSON)
        }
    }

    private static func validate(value: String, name: String, schemaJSON: String) throws {
        guard let data = schemaJSON.data(using: .utf8),
              let schema = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = schema["type"] as? String else { return }

        switch type {
        case "array", "object":
            guard let data = value.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) else {
                // ACTION 文本协议的历史参数允许用逗号分隔的 Global ID / 标签。
                // 原生 function calling 仍由 closed JSON Schema 约束；这里只保留
                // 文本兼容层，不把明显的垃圾值当作结构化数组接受。
                if type == "array", value.contains(":") || value.contains(",") || value.contains("，") {
                    return
                }
                throw ToolRuntimeError.invalidParameter(name: name, expected: "JSON \(type)", value: value)
            }
            if type == "array", !(object is [Any]) {
                throw ToolRuntimeError.invalidParameter(name: name, expected: "JSON array", value: value)
            }
            if type == "object", !(object is [String: Any]) {
                throw ToolRuntimeError.invalidParameter(name: name, expected: "JSON object", value: value)
            }
            if let enumValues = schema["enum"] as? [Any], !enumValues.contains(where: { String(describing: $0) == value }) {
                throw ToolRuntimeError.invalidParameter(name: name, expected: "枚举值", value: value)
            }
        case "integer":
            guard let number = Int(value.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw ToolRuntimeError.invalidParameter(name: name, expected: "整数", value: value)
            }
            if let minimum = schema["minimum"] as? NSNumber, number < minimum.intValue {
                throw ToolRuntimeError.invalidParameter(name: name, expected: "不小于 \(minimum.intValue)", value: value)
            }
            if let maximum = schema["maximum"] as? NSNumber, number > maximum.intValue {
                throw ToolRuntimeError.invalidParameter(name: name, expected: "不大于 \(maximum.intValue)", value: value)
            }
        case "number":
            guard let number = Double(value.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw ToolRuntimeError.invalidParameter(name: name, expected: "数字", value: value)
            }
            if let minimum = schema["minimum"] as? NSNumber, number < minimum.doubleValue {
                throw ToolRuntimeError.invalidParameter(name: name, expected: "不小于 \(minimum.doubleValue)", value: value)
            }
            if let maximum = schema["maximum"] as? NSNumber, number > maximum.doubleValue {
                throw ToolRuntimeError.invalidParameter(name: name, expected: "不大于 \(maximum.doubleValue)", value: value)
            }
        case "boolean":
            guard ["true", "false", "1", "0"].contains(value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) else {
                throw ToolRuntimeError.invalidParameter(name: name, expected: "布尔值", value: value)
            }
        default:
            break
        }
    }
}
