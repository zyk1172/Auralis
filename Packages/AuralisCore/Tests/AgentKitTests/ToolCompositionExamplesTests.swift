import AgentKit
import Foundation
import Testing

@Suite("Tool composition examples")
struct ToolCompositionExamplesTests {
    private func plan(_ text: String) -> AgentRequestPlan {
        AgentRequestPlan.build(userText: text, history: [])
    }

    @Test("Every composition reference is a real model-visible canonical tool")
    func referencesAreRealAndModelVisible() {
        for example in ToolCompositionExamples.all {
            #expect(!example.referencedToolNames.isEmpty, "\(example.id) 必须至少引用一个工具")
            for name in example.referencedToolNames {
                let descriptor = AgentToolRegistry.descriptor(for: name)
                #expect(descriptor != nil, "\(example.id) 引用了不存在的工具 \(name)")
                #expect(descriptor?.visibility == .model, "\(example.id) 引用了非 model-visible 工具 \(name)")
                #expect(name != "recommendation_index_commit")
            }
        }
    }

    @Test("Read-only examples never reference mutation tools")
    func readOnlyExamplesReferenceOnlyReadOnlyTools() throws {
        for example in ToolCompositionExamples.readOnlyExamples {
            for name in example.referencedToolNames {
                let descriptor = try #require(AgentToolRegistry.descriptor(for: name))
                #expect(descriptor.permission == .readOnly, "\(example.id) 的 \(name) 不是只读工具")
            }
        }
    }

    @Test("System prompt renders compositions as planning hints without executable schema")
    func systemPromptIncludesCompositionHints() throws {
        let toolSearch = try #require(AgentToolRegistry.descriptor(for: "tool_search"))
        let prompt = SystemPromptBuilder.build(
            context: .init(),
            tools: [toolSearch],
            nativeToolCalling: true,
            awarenessTools: AgentToolRegistry.all
        )
        #expect(prompt.contains("常见工具组合（规划参考）"))
        #expect(prompt.contains("不是固定流程"))
        #expect(prompt.contains("library_search / library_resolve_entity → playback_play_song"))
        #expect(!prompt.contains("- recommendation_index_commit"))
    }

    @Test("Composition examples do not become an authorization source")
    func compositionsNeverGrantMutationAuthorization() {
        let instructional = plan("怎么把歌曲加入歌单？")
        #expect(instructional.authorization.allowedOperations.isEmpty)

        let instructionalDelete = plan("怎么删除歌单？")
        #expect(!instructionalDelete.authorization.allowedOperations.contains(.playlistDelete))

        let executing = plan("把稻香加入通勤歌单")
        #expect(executing.authorization.allowedOperations.contains(.playlistAdd))
    }
}
