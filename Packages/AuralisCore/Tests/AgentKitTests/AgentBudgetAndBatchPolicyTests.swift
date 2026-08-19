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
            RecommendationIndexV2BatchPolicy
                .recommendedLimit(
                    maxOutputTokens: 7_999
                ) == 8
        )

        #expect(
            RecommendationIndexV2BatchPolicy
                .recommendedLimit(
                    maxOutputTokens: 8_000
                ) == 16
        )

        #expect(
            RecommendationIndexV2BatchPolicy
                .recommendedLimit(
                    maxOutputTokens: 16_000
                ) == 32
        )

        #expect(
            RecommendationIndexV2BatchPolicy
                .recommendedLimit(
                    maxOutputTokens: 32_000
                ) == 64
        )

        #expect(
            RecommendationIndexV2BatchPolicy
                .recommendedLimit(
                    maxOutputTokens: 64_000
                ) == 100
        )

        #expect(
            RecommendationIndexV2BatchPolicy
                .recommendedLimit(
                    maxOutputTokens: 100_000
                ) == 100
        )
    }

    @Test("输出截断仍然会逐级缩小批次")
    func recommendationBatchCanRecoverFromTruncation() {
        var value = 100

        value = RecommendationIndexV2BatchPolicy
            .reducedLimit(from: value)
        #expect(value == 50)

        value = RecommendationIndexV2BatchPolicy
            .reducedLimit(from: value)
        #expect(value == 25)

        value = RecommendationIndexV2BatchPolicy
            .reducedLimit(from: value)
        #expect(value == 12)

        value = RecommendationIndexV2BatchPolicy
            .reducedLimit(from: value)
        #expect(value == 8)

        value = RecommendationIndexV2BatchPolicy
            .reducedLimit(from: value)
        #expect(value == 8)
    }

    @Test("一万首即使缩到最小批次也不会撞 10000 轮看门狗")
    func tenThousandTracksFitEmergencyWatchdog() {
        let totalTracks = 10_000
        let batchSize =
            RecommendationIndexV2BatchPolicy
                .minimumTracksPerBatch

        let batches =
            (totalTracks + batchSize - 1)
            / batchSize

        // 按最保守估算：
        // 每批一次 next/classify + 一次 write/continue
        let estimatedModelRounds =
            batches * 2

        #expect(batchSize == 8)
        #expect(batches == 1_250)
        #expect(estimatedModelRounds == 2_500)
        #expect(estimatedModelRounds < 10_000)
    }
}
