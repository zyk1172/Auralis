import AgentKit
import Testing

@Test("Canonical tool definitions have one executor and clean aliases")
func canonicalToolDefinitionsPassCoverageAudit() {
    #expect(!AgentToolRegistry.definitions.isEmpty)
    #expect(AgentToolRegistry.definitions.count == AgentToolRegistry.all.count)
    #expect(AgentToolRegistry.coverageAudit().isClean)
}

@Test("Every irreversible deletion is UI-approved and no reversible mutation is")
func toolRiskApprovalPolicyIsExplicit() {
    let irreversible = AgentToolRegistry.all.filter { $0.risk == .irreversibleDelete }
    #expect(!irreversible.isEmpty)
    #expect(irreversible.allSatisfy { $0.requiresConfirmation })

    let reversible = AgentToolRegistry.all.filter { $0.risk == .reversibleMutation }
    #expect(reversible.allSatisfy { !$0.requiresConfirmation })
}

@Test("Model-visible mutations declare a scope and operation")
func modelMutationsHaveAuthorizationMetadata() {
    let mutations = AgentToolRegistry.all.filter {
        $0.visibility == .model && $0.permission != .readOnly
    }
    #expect(!mutations.isEmpty)
    #expect(mutations.allSatisfy { $0.mutationScope != nil && $0.authorizationOperation != nil })
}
