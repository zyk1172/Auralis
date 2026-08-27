import AIKit
import Domain
import Foundation
import LocalCatalog

private extension Array where Element: Sendable {
    func asyncMap<T: Sendable>(_ transform: @Sendable (Element) async -> T) async -> [T] {
        var values: [T] = []
        values.reserveCapacity(count)
        for element in self {
            values.append(await transform(element))
        }
        return values
    }
}

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

    public static func timeoutResult(
        call: ToolCall,
        descriptor: ToolDescriptor
    ) -> ToolResult {
        ToolResult(
            call: call,
            permission: descriptor.permission,
            success: false,
            summary: "工具执行超时；结果可能未知。",
            hasIndeterminateSideEffect: descriptor.permission != .readOnly,
            failure: ToolFailureEnvelope(
                toolName: descriptor.name,
                phase: .timeout,
                code: "tool_timeout",
                retryable: false,
                safeDetails: ["indeterminate": .bool(descriptor.permission != .readOnly)]
            )
        )
    }

    public static func execute(
        _ call: ToolCall,
        bridge: AgentBridge,
        catalog: LocalCatalogStore,
        serverID: ServerID?,
        systemService: (any AgentSystemService)?,
        externalMusicService: (any AgentExternalMusicService)? = nil,
        privacyPermissions: AIPrivacyPermissions? = nil,
        allowsLyrics: Bool = false,
        allowsFavoritesAndRatings: Bool = false,
        providerCapabilities: ModelCapabilities? = nil,
        webService: (any AgentWebService)? = nil,
        authorizationContext: SideEffectAuthorizationContext? = nil,
        activeSkillID: String? = nil,
        executionAuthority: ToolExecutionAuthority? = nil,
        executionLease: ToolExecutionLease,
        resourceLeaseRegistry: MutationResourceLeaseRegistry = MutationResourceLeaseRegistry(),
        recommendationIndexExecutionRegistry: RecommendationIndexExecutionRegistry = RecommendationIndexExecutionRegistry(),
        customToolRegistry: CustomToolRegistry = .shared,
        availableToolDescriptors: [ToolDescriptor] = AgentToolRegistry.all,
        capabilityEnvironment: AgentCapabilityEnvironment? = nil
    ) async -> ToolResult {
        var resolvedPrivacy = privacyPermissions ?? AIPrivacyPermissions()
        if privacyPermissions == nil {
            resolvedPrivacy.allowsLyrics = allowsLyrics
            resolvedPrivacy.allowsFavoritesAndRatings = allowsFavoritesAndRatings
        }
        let descriptor: ToolDescriptor?
        if let builtIn = AgentToolRegistry.descriptor(for: call.name) {
            descriptor = builtIn
        } else {
            descriptor = await customToolRegistry.descriptor(named: call.name)
        }
        guard let descriptor else {
            return ToolResult(
                call: call,
                permission: .readOnly,
                success: false,
                summary: ToolRuntimeError.unknownTool(call.name).localizedDescription,
                failure: ToolFailureEnvelope(
                    toolName: call.name,
                    phase: .discovery,
                    code: "unknown_tool",
                    retryable: false
                )
            )
        }

        if let denial = ToolPrivacyPolicy.denialResult(
            for: descriptor,
            call: call,
            permissions: resolvedPrivacy
        ) {
            return denial
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
               descriptor.authorizationOperation == nil,
               descriptor.customToolID == nil {
                throw ToolRuntimeError.modelWriteMissingAuthorizationOperation(call.name)
            }
            try validate(call, descriptor: descriptor)
            if descriptor.permission != .readOnly {
                guard let authorizationContext else {
                    throw ToolRuntimeError.mutationAuthorizationMissing(call.name)
                }
                switch authorizationContext.decision(for: descriptor, call: call) {
                case .allowed:
                    break
                case let .denied(reason):
                    return ToolResult(
                        call: call,
                        permission: descriptor.permission,
                        success: false,
                        summary: reason,
                        failure: ToolFailureEnvelope(
                            toolName: descriptor.name,
                            phase: .authorization,
                            code: "mutation_authorization_denied",
                            retryable: false
                        )
                    )
                }
                guard await executionLease.isValid() else {
                    throw ToolRuntimeError.executionLeaseRevoked(call.name)
                }
            }
            let executorContext = ToolExecutorContext(
                bridge: bridge,
                catalog: catalog,
                serverID: serverID,
                systemService: systemService,
                externalMusicService: externalMusicService,
                privacyPermissions: resolvedPrivacy,
                allowsLyrics: allowsLyrics,
                allowsFavoritesAndRatings: allowsFavoritesAndRatings,
                providerCapabilities: providerCapabilities,
                webService: webService,
                authorizationContext: authorizationContext,
                activeSkillID: activeSkillID,
                executionAuthority: executionAuthority,
                executionLease: executionLease,
                resourceLeaseRegistry: resourceLeaseRegistry,
                recommendationIndexExecutionRegistry: recommendationIndexExecutionRegistry,
                customToolRegistry: customToolRegistry,
                availableToolDescriptors: availableToolDescriptors,
                capabilityEnvironment: capabilityEnvironment
            )
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
                        privacyPermissions: resolvedPrivacy,
                        allowsLyrics: allowsLyrics,
                        allowsFavoritesAndRatings: allowsFavoritesAndRatings,
                        providerCapabilities: providerCapabilities,
                        webService: webService,
                        activeSkillID: activeSkillID,
                        recommendationIndexExecutionRegistry: recommendationIndexExecutionRegistry,
                        executionContext: executorContext
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
                    privacyPermissions: resolvedPrivacy,
                    allowsLyrics: allowsLyrics,
                    allowsFavoritesAndRatings: allowsFavoritesAndRatings,
                    providerCapabilities: providerCapabilities,
                    webService: webService,
                    activeSkillID: activeSkillID,
                    recommendationIndexExecutionRegistry: recommendationIndexExecutionRegistry,
                    executionContext: executorContext
                )
            }
            return result
        } catch {
            let runtimeError = error as? ToolRuntimeError
            return ToolResult(
                call: call,
                permission: descriptor.permission,
                success: false,
                summary: runtimeError.map { $0.localizedDescription }
                    ?? "工具执行失败：\(error.localizedDescription)",
                failure: failureEnvelope(for: runtimeError, toolName: descriptor.name)
            )
        }
    }

    /// Instrumented entry point used by production ToolLoop paths. The
    /// underlying protocol and executor remain identical to `execute`; this
    /// wrapper only records safe duration facts and never records arguments or
    /// response contents.
    public static func executeMeasured(
        _ call: ToolCall,
        bridge: AgentBridge,
        catalog: LocalCatalogStore,
        serverID: ServerID?,
        systemService: (any AgentSystemService)?,
        externalMusicService: (any AgentExternalMusicService)? = nil,
        privacyPermissions: AIPrivacyPermissions? = nil,
        allowsLyrics: Bool = false,
        allowsFavoritesAndRatings: Bool = false,
        providerCapabilities: ModelCapabilities? = nil,
        webService: (any AgentWebService)? = nil,
        authorizationContext: SideEffectAuthorizationContext? = nil,
        activeSkillID: String? = nil,
        executionAuthority: ToolExecutionAuthority? = nil,
        executionLease: ToolExecutionLease,
        resourceLeaseRegistry: MutationResourceLeaseRegistry = MutationResourceLeaseRegistry(),
        recommendationIndexExecutionRegistry: RecommendationIndexExecutionRegistry = RecommendationIndexExecutionRegistry(),
        customToolRegistry: CustomToolRegistry = .shared,
        availableToolDescriptors: [ToolDescriptor] = AgentToolRegistry.all,
        capabilityEnvironment: AgentCapabilityEnvironment? = nil,
        runID: UUID? = nil,
        callID: String? = nil,
        metricsCollector: ToolMetricsCollector? = .shared
    ) async -> ToolResult {
        let started = Date().timeIntervalSinceReferenceDate
        let discoveryStarted = started
        let descriptor: ToolDescriptor? = if let descriptor = AgentToolRegistry.descriptor(for: call.name) {
            descriptor
        } else {
            await customToolRegistry.descriptor(named: call.name)
        }
        let discoveryMilliseconds = milliseconds(since: discoveryStarted)

        let validationStarted = Date().timeIntervalSinceReferenceDate
        if let descriptor {
            try? validate(call, descriptor: descriptor)
        }
        let validationMilliseconds = milliseconds(since: validationStarted)
        let executorStarted = Date().timeIntervalSinceReferenceDate
        let result = await execute(
            call,
            bridge: bridge,
            catalog: catalog,
            serverID: serverID,
            systemService: systemService,
            externalMusicService: externalMusicService,
            privacyPermissions: privacyPermissions,
            allowsLyrics: allowsLyrics,
            allowsFavoritesAndRatings: allowsFavoritesAndRatings,
            providerCapabilities: providerCapabilities,
            webService: webService,
            authorizationContext: authorizationContext,
            activeSkillID: activeSkillID,
            executionAuthority: executionAuthority,
            executionLease: executionLease,
            resourceLeaseRegistry: resourceLeaseRegistry,
            recommendationIndexExecutionRegistry: recommendationIndexExecutionRegistry,
            customToolRegistry: customToolRegistry,
            availableToolDescriptors: availableToolDescriptors,
            capabilityEnvironment: capabilityEnvironment
        )
        let executorMilliseconds = milliseconds(since: executorStarted)
        if let metricsCollector {
            await metricsCollector.record(ToolExecutionMetrics(
                runID: runID ?? executionLease.runID,
                callID: callID,
                toolName: call.name,
                discoveryMilliseconds: discoveryMilliseconds,
                validationMilliseconds: validationMilliseconds,
                executorMilliseconds: executorMilliseconds
            ))
        }
        return result
    }

    private static func milliseconds(since start: TimeInterval) -> Double {
        max(0, (Date().timeIntervalSinceReferenceDate - start) * 1_000)
    }

    /// Execute an independent read-only provider turn concurrently while
    /// preserving provider call order in the returned array. Any mutation,
    /// confirmation-bearing or non-parallel-safe descriptor falls back to the
    /// ordinary sequential path; this helper never weakens Runtime guards.
    public static func executeReadOnlyParallel(
        _ calls: [ToolCall],
        context: ToolExecutorContext,
        providerAllowsParallel: Bool,
        runID: UUID? = nil,
        metricsCollector: ToolMetricsCollector? = .shared
    ) async -> [ToolResult] {
        guard calls.count > 1, providerAllowsParallel else {
            return await calls.asyncMap { call in
                await executeMeasured(
                    call,
                    bridge: context.bridge,
                    catalog: context.catalog,
                    serverID: context.serverID,
                    systemService: context.systemService,
                    externalMusicService: context.externalMusicService,
                    privacyPermissions: context.privacyPermissions,
                    allowsLyrics: context.allowsLyrics,
                    allowsFavoritesAndRatings: context.allowsFavoritesAndRatings,
                    providerCapabilities: context.providerCapabilities,
                    webService: context.webService,
                    authorizationContext: context.authorizationContext,
                    activeSkillID: context.activeSkillID,
                    executionAuthority: context.executionAuthority,
                    executionLease: context.executionLease,
                    resourceLeaseRegistry: context.resourceLeaseRegistry,
                    recommendationIndexExecutionRegistry: context.recommendationIndexExecutionRegistry,
                    customToolRegistry: context.customToolRegistry,
                    availableToolDescriptors: context.availableToolDescriptors,
                    capabilityEnvironment: context.capabilityEnvironment,
                    runID: runID,
                    callID: nil,
                    metricsCollector: metricsCollector
                )
            }
        }

        var descriptors: [ToolDescriptor?] = []
        descriptors.reserveCapacity(calls.count)
        for call in calls {
            if let descriptor = context.availableToolDescriptors.first(where: { $0.name == call.name || $0.aliases.contains(call.name) }) {
                descriptors.append(descriptor)
            } else if let descriptor = AgentToolRegistry.descriptor(for: call.name) {
                descriptors.append(descriptor)
            } else {
                descriptors.append(await context.customToolRegistry.descriptor(named: call.name))
            }
        }
        guard descriptors.allSatisfy({ descriptor in
            guard let descriptor else { return false }
            return descriptor.permission == .readOnly
                && descriptor.parallelSafe
                && !descriptor.confirmationPolicy.requiresExplicitUserApproval
        }) else {
            return await calls.asyncMap { call in
                await executeMeasured(
                    call,
                    bridge: context.bridge,
                    catalog: context.catalog,
                    serverID: context.serverID,
                    systemService: context.systemService,
                    externalMusicService: context.externalMusicService,
                    privacyPermissions: context.privacyPermissions,
                    allowsLyrics: context.allowsLyrics,
                    allowsFavoritesAndRatings: context.allowsFavoritesAndRatings,
                    providerCapabilities: context.providerCapabilities,
                    webService: context.webService,
                    authorizationContext: context.authorizationContext,
                    activeSkillID: context.activeSkillID,
                    executionAuthority: context.executionAuthority,
                    executionLease: context.executionLease,
                    resourceLeaseRegistry: context.resourceLeaseRegistry,
                    recommendationIndexExecutionRegistry: context.recommendationIndexExecutionRegistry,
                    customToolRegistry: context.customToolRegistry,
                    availableToolDescriptors: context.availableToolDescriptors,
                    capabilityEnvironment: context.capabilityEnvironment,
                    runID: runID,
                    callID: nil,
                    metricsCollector: metricsCollector
                )
            }
        }

        var indexedResults: [(Int, ToolResult)] = []
        indexedResults.reserveCapacity(calls.count)
        await withTaskGroup(of: (Int, ToolResult).self) { group in
            for (index, call) in calls.enumerated() {
                group.addTask {
                    let result = await executeMeasured(
                        call,
                        bridge: context.bridge,
                        catalog: context.catalog,
                        serverID: context.serverID,
                        systemService: context.systemService,
                        externalMusicService: context.externalMusicService,
                        privacyPermissions: context.privacyPermissions,
                        allowsLyrics: context.allowsLyrics,
                        allowsFavoritesAndRatings: context.allowsFavoritesAndRatings,
                        providerCapabilities: context.providerCapabilities,
                        webService: context.webService,
                        authorizationContext: context.authorizationContext,
                        activeSkillID: context.activeSkillID,
                        executionAuthority: context.executionAuthority,
                        executionLease: context.executionLease,
                        resourceLeaseRegistry: context.resourceLeaseRegistry,
                        recommendationIndexExecutionRegistry: context.recommendationIndexExecutionRegistry,
                        customToolRegistry: context.customToolRegistry,
                        availableToolDescriptors: context.availableToolDescriptors,
                    capabilityEnvironment: context.capabilityEnvironment,
                        runID: runID,
                        callID: nil,
                        metricsCollector: metricsCollector
                    )
                    return (index, result)
                }
            }
            for await item in group {
                indexedResults.append(item)
            }
        }
        return indexedResults.sorted { $0.0 < $1.0 }.map(\.1)
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

    private static func failureEnvelope(
        for error: ToolRuntimeError?,
        toolName: String
    ) -> ToolFailureEnvelope {
        let phase: ToolFailureEnvelope.Phase
        let code: String
        let retryable: Bool
        switch error {
        case .unknownTool:
            phase = .discovery; code = "unknown_tool"; retryable = false
        case .missingParameter, .unknownParameter, .invalidParameter:
            phase = .inputValidation; code = "invalid_arguments"; retryable = false
        case .skillUnavailable:
            phase = .authorization; code = "skill_unavailable"; retryable = false
        case .modelWriteMissingAuthorizationOperation:
            phase = .authorization; code = "missing_authorization_operation"; retryable = false
        case .mutationAuthorizationMissing:
            phase = .authorization; code = "missing_authorization_context"; retryable = false
        case .executionLeaseRevoked:
            phase = .resourceLease; code = "execution_lease_revoked"; retryable = false
        case .mutationResourceBusy:
            phase = .resourceLease; code = "mutation_resource_busy"; retryable = true
        case nil:
            phase = .execution; code = "tool_execution_failed"; retryable = false
        }
        return ToolFailureEnvelope(
            toolName: toolName,
            phase: phase,
            code: code,
            retryable: retryable
        )
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
