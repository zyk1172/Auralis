import Foundation

/// Timing facts for one tool call.  Values are durations in milliseconds and
/// contain no request bodies, arguments or credentials.
public struct ToolExecutionMetrics: Codable, Sendable, Equatable, Hashable {
    public let runID: UUID
    public let callID: String?
    public let toolName: String
    public let modelPlanningMilliseconds: Double
    public let discoveryMilliseconds: Double
    public let validationMilliseconds: Double
    public let resourceWaitMilliseconds: Double
    public let resolutionMilliseconds: Double
    public let executorMilliseconds: Double
    public let networkMilliseconds: Double
    public let resultEncodingMilliseconds: Double
    public let modelFinalizationMilliseconds: Double

    public init(
        runID: UUID,
        callID: String?,
        toolName: String,
        modelPlanningMilliseconds: Double = 0,
        discoveryMilliseconds: Double = 0,
        validationMilliseconds: Double = 0,
        resourceWaitMilliseconds: Double = 0,
        resolutionMilliseconds: Double = 0,
        executorMilliseconds: Double = 0,
        networkMilliseconds: Double = 0,
        resultEncodingMilliseconds: Double = 0,
        modelFinalizationMilliseconds: Double = 0
    ) {
        self.runID = runID
        self.callID = callID
        self.toolName = toolName
        self.modelPlanningMilliseconds = max(0, modelPlanningMilliseconds)
        self.discoveryMilliseconds = max(0, discoveryMilliseconds)
        self.validationMilliseconds = max(0, validationMilliseconds)
        self.resourceWaitMilliseconds = max(0, resourceWaitMilliseconds)
        self.resolutionMilliseconds = max(0, resolutionMilliseconds)
        self.executorMilliseconds = max(0, executorMilliseconds)
        self.networkMilliseconds = max(0, networkMilliseconds)
        self.resultEncodingMilliseconds = max(0, resultEncodingMilliseconds)
        self.modelFinalizationMilliseconds = max(0, modelFinalizationMilliseconds)
    }

    public var totalMilliseconds: Double {
        modelPlanningMilliseconds
            + discoveryMilliseconds
            + validationMilliseconds
            + resourceWaitMilliseconds
            + resolutionMilliseconds
            + executorMilliseconds
            + networkMilliseconds
            + resultEncodingMilliseconds
            + modelFinalizationMilliseconds
    }
}

/// Process-local metrics sink.  It is intentionally bounded so a long-lived
/// app cannot grow memory merely because a user has a busy tool loop.
public actor ToolMetricsCollector {
    public static let shared = ToolMetricsCollector()
    private let capacity: Int
    private var values: [ToolExecutionMetrics] = []

    public init(capacity: Int = 512) {
        self.capacity = max(1, capacity)
    }

    public func record(_ metrics: ToolExecutionMetrics) {
        values.append(metrics)
        if values.count > capacity {
            values.removeFirst(values.count - capacity)
        }
    }

    public func snapshot() -> [ToolExecutionMetrics] { values }

    public func latest(for toolName: String? = nil) -> ToolExecutionMetrics? {
        if let toolName {
            return values.reversed().first { $0.toolName == toolName }
        }
        return values.last
    }

    public func reset() { values.removeAll(keepingCapacity: true) }
}
