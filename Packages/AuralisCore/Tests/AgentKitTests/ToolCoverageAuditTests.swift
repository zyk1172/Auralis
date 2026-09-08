// SPDX-License-Identifier: GPL-3.0-only
import AgentKit
import Foundation
import Testing

@Test("Canonical tool definitions have one executor and clean aliases")
func canonicalToolDefinitionsPassCoverageAudit() {
    #expect(!AgentToolRegistry.definitions.isEmpty)
    #expect(AgentToolRegistry.definitions.count == AgentToolRegistry.all.count)
    #expect(AgentToolRegistry.coverageAudit().isClean)
}

@Test("Canonical aliases are legal, unique, and resolve before legacy exact names")
func canonicalAliasesResolveToTheirDeclaredTarget() {
    let canonicalNames = Set(
        AgentToolRegistry.all
            .filter { $0.visibility != .legacyOnly }
            .map(\.name)
    )
    var owners: [String: String] = [:]

    for descriptor in AgentToolRegistry.all where descriptor.visibility != .legacyOnly {
        for alias in descriptor.aliases {
            #expect(!alias.isEmpty)
            #expect(alias.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-.=")).contains($0)
            })
            #expect(!canonicalNames.contains(alias), "alias \(alias) must not shadow a canonical name")
            #expect(owners[alias] == nil || owners[alias] == descriptor.name, "alias \(alias) has multiple owners")
            owners[alias] = descriptor.name
            #expect(AgentToolRegistry.descriptor(for: alias)?.name == descriptor.name)
            #expect(AgentToolRegistry.definition(for: alias)?.descriptor.name == descriptor.name)
        }
    }

    // `listPlaylists` is both a retained legacy exact descriptor and the
    // canonical playlist alias; the canonical metadata wins at lookup time.
    #expect(AgentToolRegistry.descriptor(for: "listPlaylists")?.name == "playlist_list")
}

@Test("Destructive tools are UI-approved while ordinary local mutations stay frictionless")
func toolRiskApprovalPolicyIsExplicit() {
    let irreversible = AgentToolRegistry.all.filter { $0.risk == .irreversibleDelete }
    #expect(!irreversible.isEmpty)
    #expect(irreversible.allSatisfy { $0.confirmationPolicy.requiresExplicitUserApproval })

    let destructive = AgentToolRegistry.all.filter { $0.permission == .destructive }
    #expect(destructive.allSatisfy { $0.requiresExplicitUserApproval })

    // A composite custom tool may inherit a child confirmation policy even
    // when its derived risk remains reversible. Built-in ordinary mutations
    // do not carry an extra approval layer.
    let builtInReversible = AgentToolRegistry.all.filter {
        $0.customToolID == nil && $0.risk == .reversibleMutation
    }
    #expect(builtInReversible.allSatisfy { !$0.confirmationPolicy.requiresExplicitUserApproval })
}

@Test("Model-visible mutations declare a scope and operation")
func modelMutationsHaveAuthorizationMetadata() {
    let mutations = AgentToolRegistry.all.filter {
        $0.visibility == .model && $0.permission != .readOnly
    }
    #expect(!mutations.isEmpty)
    #expect(mutations.allSatisfy { $0.mutationScope != nil && $0.authorizationOperation != nil })
}
