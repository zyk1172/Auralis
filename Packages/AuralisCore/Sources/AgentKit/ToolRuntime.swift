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
    case skillUnavailable(String)
    case modelWriteMissingAuthorizationOperation(String)
    case mutationAuthorizationMissing(String)
    case executionLeaseRevoked(String)
    case mutationResourceBusy(String)

    public var errorDescription: String? {
        switch self {
        case let .unknownTool(name): "未知工具：\(name)"
        case let .missingParameter(name): "缺少必填参数：\(name)"
        case let .unknownParameter(name): "工具不接受参数：\(name)"
        case let .invalidParameter(name, expected, value): "参数 \(name) 应为 \(expected)，实际为：\(value)"
        case let .skillUnavailable(name): "工具 \(name) 只能由受信任的内置 Skill 执行"
        case let .modelWriteMissingAuthorizationOperation(name): "工具 \(name) 缺少副作用授权操作声明，已拒绝执行"
        case let .mutationAuthorizationMissing(name): "工具 \(name) 缺少当前请求的副作用授权，已拒绝执行"
        case let .executionLeaseRevoked(name): "工具 \(name) 所属运行已失效，未执行副作用"
        case let .mutationResourceBusy(resource): "资源 \(resource) 正被另一个运行修改，当前操作未执行"
        }
    }
}

/// Capability granted by a trusted Runtime to one deterministic Skill.  It is
/// independent from user-language authorization: an internal primitive needs
/// both the originating lineage authorization and this scoped authority.
public struct ToolExecutionAuthority: Sendable, Equatable {
    public let skillID: String
    public let lineageID: UUID
    public let generation: UInt64

    public init(skillID: String, lineageID: UUID, generation: UInt64) {
        self.skillID = skillID
        self.lineageID = lineageID
        self.generation = generation
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
        webService: (any AgentWebService)? = nil,
        authorizationContext: SideEffectAuthorizationContext? = nil,
        activeSkillID: String? = nil,
        executionAuthority: ToolExecutionAuthority? = nil,
        executionLease: ToolExecutionLease,
        resourceLeaseRegistry: MutationResourceLeaseRegistry = MutationResourceLeaseRegistry()
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
            // Internal state-machine primitives are executable only by their
            // trusted built-in skill.  Visibility controls discovery; this is
            // the runtime enforcement boundary for direct/malformed calls.
            if let requiredSkillID = descriptor.requiredSkillID {
                guard executionAuthority?.skillID == requiredSkillID else {
                    throw ToolRuntimeError.skillUnavailable(call.name)
                }
            }
            if descriptor.visibility == .model,
               descriptor.permission != .readOnly,
               descriptor.authorizationOperation == nil {
                throw ToolRuntimeError.modelWriteMissingAuthorizationOperation(call.name)
            }
            try validate(call, descriptor: descriptor)
            if descriptor.permission != .readOnly {
                guard let authorizationContext else {
                    throw ToolRuntimeError.mutationAuthorizationMissing(call.name)
                }
                guard authorizationContext.allows(descriptor) else {
                    return ToolResult(
                        call: call,
                        permission: descriptor.permission,
                        success: false,
                        summary: authorizationContext.denialReason(for: descriptor)
                    )
                }
                guard await executionLease.isValid() else {
                    throw ToolRuntimeError.executionLeaseRevoked(call.name)
                }
            }
            let resources = descriptor.mutationResources
            if !resources.isEmpty {
                guard await resourceLeaseRegistry.tryAcquire(resources, owner: executionLease.runID) else {
                    let resource = resources.map(\.rawValue).sorted().joined(separator: ", ")
                    throw ToolRuntimeError.mutationResourceBusy(resource)
                }
                // The registry acquisition itself suspends. Re-check after it
                // and immediately before entering the executor so a revoked
                // run cannot use a resource acquired just before cancellation.
                guard await executionLease.isValid() else {
                    await resourceLeaseRegistry.release(resources, owner: executionLease.runID)
                    throw ToolRuntimeError.executionLeaseRevoked(call.name)
                }
                let result = await ToolExecutionContext.$lease.withValue(executionLease) {
                    await AgentToolRegistry.execute(
                        call,
                        bridge: bridge,
                        catalog: catalog,
                        serverID: serverID,
                        systemService: systemService,
                        externalMusicService: externalMusicService,
                        allowsLyrics: allowsLyrics,
                        providerCapabilities: providerCapabilities,
                        webService: webService,
                        activeSkillID: activeSkillID
                    )
                }
                await resourceLeaseRegistry.release(resources, owner: executionLease.runID)
                return result
            }
            let result = await ToolExecutionContext.$lease.withValue(executionLease) {
                await AgentToolRegistry.execute(
                    call,
                    bridge: bridge,
                    catalog: catalog,
                    serverID: serverID,
                    systemService: systemService,
                    externalMusicService: externalMusicService,
                    allowsLyrics: allowsLyrics,
                    providerCapabilities: providerCapabilities,
                    webService: webService,
                    activeSkillID: activeSkillID
                )
            }
            return result
        } catch {
            return ToolResult(
                call: call,
                permission: descriptor.permission,
                success: false,
                summary: error is ToolRuntimeError
                    ? error.localizedDescription
                    : "工具执行失败：\(error.localizedDescription)"
            )
        }
    }

    public static func validate(_ call: ToolCall, descriptor: ToolDescriptor) throws {
        let definitions = Dictionary(uniqueKeysWithValues: descriptor.parameters.map { ($0.name, $0) })
        for name in call.arguments.keys where definitions[name] == nil {
            throw ToolRuntimeError.unknownParameter(name)
        }
        for parameter in descriptor.parameters where parameter.required {
            let value = call.arguments[parameter.name]
            guard let value, !isMissing(value) else {
                throw ToolRuntimeError.missingParameter(parameter.name)
            }
        }
        for parameter in descriptor.parameters {
            let value = call.arguments[parameter.name]
            guard let value, let schemaJSON = parameter.schemaJSON else { continue }
            try validate(value: value, name: parameter.name, schemaJSON: schemaJSON)
        }
    }

    private static func isMissing(_ value: AIJSONValue) -> Bool {
        switch value {
        case .null: return true
        case let .string(value): return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        default: return false
        }
    }

    private static func validate(value: AIJSONValue, name: String, schemaJSON: String) throws {
        guard let data = schemaJSON.data(using: .utf8),
              let rawSchema = try? AIJSONValue(jsonData: data),
              case let .object(schema) = rawSchema else { return }
        try validate(value: value, name: name, schema: schema, path: name)
    }

    private static func validate(
        value originalValue: AIJSONValue,
        name: String,
        schema: [String: AIJSONValue],
        path: String
    ) throws {
        let value = legacyStructuredValue(originalValue, expectedType: stringValue(schema["type"]))
        if let enumValue = schema["enum"],
           case let .array(values) = enumValue,
           !values.contains(value) {
            throw invalid(name: name, expected: "枚举值", value: value)
        }

        guard let type = stringValue(schema["type"]) else { return }
        switch type {
        case "null":
            guard value == .null else { throw invalid(name: name, expected: "null", value: value) }
        case "string":
            guard case .string = value else { throw invalid(name: name, expected: "字符串", value: value) }
        case "boolean":
            guard case .bool = value else { throw invalid(name: name, expected: "布尔值", value: value) }
        case "integer":
            guard case let .number(number) = value, number.isFinite, number.rounded() == number else {
                throw invalid(name: name, expected: "整数", value: value)
            }
            try validateNumber(number, name: name, schema: schema, value: value)
        case "number":
            guard case let .number(number) = value, number.isFinite else {
                throw invalid(name: name, expected: "数字", value: value)
            }
            try validateNumber(number, name: name, schema: schema, value: value)
        case "array":
            guard case let .array(items) = value else {
                throw invalid(name: name, expected: "JSON array", value: value)
            }
            if let minimum = intValue(schema["minItems"]), items.count < minimum {
                throw invalid(name: name, expected: "数组至少包含 \(minimum) 项", value: value)
            }
            if let maximum = intValue(schema["maxItems"]), items.count > maximum {
                throw invalid(name: name, expected: "数组最多包含 \(maximum) 项", value: value)
            }
            if case let .object(itemSchema) = schema["items"] {
                for (index, item) in items.enumerated() {
                    try validate(value: item, name: name, schema: itemSchema, path: "\(path)[\(index)]")
                }
            }
        case "object":
            guard case let .object(object) = value else {
                throw invalid(name: name, expected: "JSON object", value: value)
            }
            let properties = objectValue(schema["properties"])
            if case let .array(required) = schema["required"] {
                for item in required.compactMap(stringValue) where object[item].map(isMissing) ?? true {
                    throw ToolRuntimeError.missingParameter("\(path).\(item)")
                }
            }
            let allowsAdditional = boolValue(schema["additionalProperties"]) ?? true
            if !allowsAdditional {
                for key in object.keys where properties[key] == nil {
                    throw ToolRuntimeError.unknownParameter("\(path).\(key)")
                }
            }
            for (key, propertySchema) in properties {
                guard let item = object[key], case let .object(propertySchema) = propertySchema else { continue }
                try validate(value: item, name: name, schema: propertySchema, path: "\(path).\(key)")
            }
        default:
            break
        }
    }

    private static func validateNumber(
        _ number: Double,
        name: String,
        schema: [String: AIJSONValue],
        value: AIJSONValue
    ) throws {
        if let minimum = doubleValue(schema["minimum"]), number < minimum {
            throw invalid(name: name, expected: "不小于 \(minimum)", value: value)
        }
        if let maximum = doubleValue(schema["maximum"]), number > maximum {
            throw invalid(name: name, expected: "不大于 \(maximum)", value: value)
        }
    }

    private static func legacyStructuredValue(_ value: AIJSONValue, expectedType: String?) -> AIJSONValue {
        guard case let .string(raw) = value, expectedType == "array" || expectedType == "object" else {
            // ACTION compatibility keeps scalar text as text. Native values
            // already arrive as the correct JSON kind.
            if case let .string(raw) = value, expectedType == "integer", let number = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return .number(Double(number))
            }
            if case let .string(raw) = value, expectedType == "number", let number = Double(raw.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return .number(number)
            }
            if case let .string(raw) = value, expectedType == "boolean" {
                switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
                case "true", "1": return .bool(true)
                case "false", "0": return .bool(false)
                default: break
                }
            }
            return value
        }
        if let parsed = try? AIJSONValue(jsonString: raw) { return parsed }
        return value
    }

    private static func stringValue(_ value: AIJSONValue?) -> String? {
        guard case let .string(string) = value else { return nil }
        return string
    }

    private static func intValue(_ value: AIJSONValue?) -> Int? {
        switch value {
        case let .number(number) where number.rounded() == number: return Int(number)
        case let .string(string): return Int(string)
        default: return nil
        }
    }

    private static func doubleValue(_ value: AIJSONValue?) -> Double? {
        switch value {
        case let .number(number): return number
        case let .string(string): return Double(string)
        default: return nil
        }
    }

    private static func boolValue(_ value: AIJSONValue?) -> Bool? {
        guard case let .bool(value) = value else { return nil }
        return value
    }

    private static func objectValue(_ value: AIJSONValue?) -> [String: AIJSONValue] {
        guard case let .object(value) = value else { return [:] }
        return value
    }

    private static func invalid(name: String, expected: String, value: AIJSONValue) -> ToolRuntimeError {
        let display: String
        if case let .string(string) = value {
            display = string
        } else {
            display = value.jsonString
        }
        return .invalidParameter(name: name, expected: expected, value: display)
    }
}
