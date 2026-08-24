import AIKit
import Testing
@testable import AgentKit

@Suite("Agent 大批量任务预算")
struct AgentBudgetAndBatchPolicyTests {
    @Test("默认 Agent Token 预算跟随 Provider")
    func defaultBudgetFollowsProvider() {
        let capabilities = ModelCapabilities(
            maxContextTokens: 1_000_000,
            maxOutputTokens: 100_000,
            supportsToolCalling: true
        )

        let budget = AgentTaskBudget()

        #expect(
            budget.maxInputTokens
                == AgentTaskBudget.followProvider
        )

        #expect(
            budget.maxOutputTokens
                == AgentTaskBudget.followProvider
        )

        #expect(
            budget.resolvedInputTokens(
                capabilities: capabilities
            ) == 1_000_000
        )

        #expect(
            budget.resolvedOutputTokens(
                capabilities: capabilities
            ) == 100_000
        )
    }

    @Test("显式任务限制仍然可以低于 Provider")
    func explicitBudgetCanStillRestrictProvider() {
        let capabilities = ModelCapabilities(
            maxContextTokens: 1_000_000,
            maxOutputTokens: 100_000
        )

        let budget = AgentTaskBudget(
            maxInputTokens: 200_000,
            maxOutputTokens: 20_000
        )

        #expect(
            budget.resolvedInputTokens(
                capabilities: capabilities
            ) == 200_000
        )

        #expect(
            budget.resolvedOutputTokens(
                capabilities: capabilities
            ) == 20_000
        )
    }

    @Test("完整推荐索引不再写死 256K/16K")
    func fullIndexFollowsProvider() {
        let policy = AgentTaskPolicyResolver.resolve(
            text: "开始并一次性完成推荐索引 V2，持续分批分类并写回，直到待分类为 0。",
            explicitIntent: .libraryManagement
        )

        #expect(
            policy.completion
                == .indexPendingCountIsZero
        )

        #expect(
            policy.budget.maxInputTokens
                == AgentTaskBudget.followProvider
        )

        #expect(
            policy.budget.maxOutputTokens
                == AgentTaskBudget.followProvider
        )

        #expect(
            policy.budget.wallClockSeconds
                == 24 * 60 * 60
        )

        #expect(
            policy.budget.maxModelRounds
                == 10_000
        )
    }

    @Test("Recommendation Index 根据输出能力扩大批次")
    func recommendationBatchScalesWithOutput() {
        #expect(
            RecommendationIndexBatchPolicy
                .recommendedLimit(
                    maxOutputTokens: 7_999
                ) == 8
        )

        #expect(
            RecommendationIndexBatchPolicy
                .recommendedLimit(
                    maxOutputTokens: 8_000
                ) == 16
        )

        #expect(
            RecommendationIndexBatchPolicy
                .recommendedLimit(
                    maxOutputTokens: 16_000
                ) == 32
        )

        #expect(
            RecommendationIndexBatchPolicy
                .recommendedLimit(
                    maxOutputTokens: 32_000
                ) == 64
        )

        #expect(
            RecommendationIndexBatchPolicy
                .recommendedLimit(
                    maxOutputTokens: 64_000
                ) == 100
        )

        #expect(
            RecommendationIndexBatchPolicy
                .recommendedLimit(
                    maxOutputTokens: 100_000
                ) == 100
        )
    }

    @Test("输出截断仍然会逐级缩小批次直到单项")
    func recommendationBatchCanRecoverFromTruncation() {
        var value = 100

        value = RecommendationIndexBatchPolicy
            .reducedLimit(from: value)
        #expect(value == 50)

        value = RecommendationIndexBatchPolicy
            .reducedLimit(from: value)
        #expect(value == 25)

        value = RecommendationIndexBatchPolicy
            .reducedLimit(from: value)
        #expect(value == 12)

        value = RecommendationIndexBatchPolicy
            .reducedLimit(from: value)
        #expect(value == 6)

        value = RecommendationIndexBatchPolicy
            .reducedLimit(from: value)
        #expect(value == 3)

        value = RecommendationIndexBatchPolicy
            .reducedLimit(from: value)
        #expect(value == 1)

        value = RecommendationIndexBatchPolicy
            .reducedLimit(from: value)
        #expect(value == 1)
    }

    @Test("一万首缩到单项批次时每批仍只有一次模型分类")
    func tenThousandTracksFitEmergencyWatchdog() {
        let totalTracks = 10_000
        let batchSize =
            RecommendationIndexBatchPolicy
                .minimumTracksPerBatch

        let batches =
            (totalTracks + batchSize - 1)
            / batchSize

        // Recommendation Index 的 next / write / verify 都是 Runtime 内部
        // primitive；每批只有一次封闭的模型分类请求。
        let estimatedModelRounds =
            batches

        #expect(batchSize == 1)
        #expect(batches == 10_000)
        #expect(estimatedModelRounds == 10_000)
    }
}
