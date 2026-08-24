import AgentKit
import Application
@testable import AppShell
import Domain
import Foundation
import Testing

/// 会话隔离回归：Session A 的消息 / streaming / 迟到 callback 绝不进入 Session B 的 UI。
@Suite("Session isolation")
@MainActor
struct SessionIsolationTests {
    /// model 与 coordinator 必须在同一作用域创建并存活（coordinator 对 model 是 unowned）。
    private func makeCoordinator() -> (AuralisAppModel, AgentCoordinator) {
        let defaults = UserDefaults(suiteName: "session-isolation-\(UUID().uuidString)")!
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-isolation-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let model = AuralisAppModel(
            connector: NoopConnector(),
            defaults: defaults,
            storeURL: dir.appendingPathComponent("catalog.sqlite")
        )
        let coordinator = AgentCoordinator(model: model, coordinator: model.catalogCoordinator, directory: dir)
        return (model, coordinator)
    }

    @Test("TEST A/B：A 的 streaming 与最终回答不进入 B 的 UI，A 持久化正常")
    func sessionAMessageNeverLeaksToB() async throws {
        let (model, coordinator) = makeCoordinator()
        _ = model
        let a = await coordinator.newSession()   // 创建并激活 A
        let b = await coordinator.newSession()   // 创建并激活 B（当前 active = B）
        #expect(coordinator.activeSessionID == b)

        let runID = UUID()
        coordinator.currentRunID = runID

        // Session A 的 streaming 增量到达（active 是 B）：UI 不更新。
        await coordinator.receive(
            AgentChatMessage(role: .assistant, messages: [.streaming("来自 A 的流式内容")]),
            sessionID: a, runID: runID
        )
        #expect(coordinator.messages.allSatisfy { !$0.messages.contains { item in
            if case let .streaming(t) = item { return t.contains("来自 A") }
            return false
        } })

        // Session A 的最终回答到达：B 的 UI 不出现 A 的内容，但 A 的 SessionStore 已持久化。
        await coordinator.receive(
            AgentChatMessage(role: .assistant, messages: [.text("A 的最终回答")]),
            sessionID: a, runID: runID
        )
        #expect(coordinator.messages.allSatisfy { !$0.messages.contains { item in
            if case let .text(t) = item { return t.contains("A 的最终回答") }
            return false
        } })

        // 切回 A：A 的消息出现（历史来自 SessionStore）。
        await coordinator.activate(a)
        #expect(coordinator.messages.contains { $0.messages.contains { item in
            if case let .text(t) = item { return t == "A 的最终回答" }
            return false
        } })
    }

    @Test("TEST D：迟到 callback（旧 runID）被丢弃，不污染新运行/新会话")
    func lateCallbackDiscarded() async throws {
        let (model, coordinator) = makeCoordinator()
        _ = model
        let a = await coordinator.newSession()
        let oldRun = UUID()
        coordinator.currentRunID = oldRun
        await coordinator.receive(
            AgentChatMessage(role: .assistant, messages: [.text("旧运行的回答")]),
            sessionID: a, runID: oldRun
        )
        // 新运行开始：currentRunID 换成新 runID。
        let newRun = UUID()
        coordinator.currentRunID = newRun
        // 旧 run 的迟到 token / final answer 到达 → 丢弃。
        await coordinator.receive(
            AgentChatMessage(role: .assistant, messages: [.streaming("迟到内容")]),
            sessionID: a, runID: oldRun
        )
        await coordinator.receive(
            AgentChatMessage(role: .assistant, messages: [.text("旧运行的迟到回答")]),
            sessionID: a, runID: oldRun
        )
        #expect(coordinator.messages.contains { $0.messages.contains { item in
            if case let .text(t) = item { return t.contains("迟到") }
            return false
        } } == false)
        // 新运行正常写回。
        await coordinator.receive(
            AgentChatMessage(role: .assistant, messages: [.text("新运行的回答")]),
            sessionID: a, runID: newRun
        )
        #expect(coordinator.messages.contains { $0.messages.contains { item in
            if case let .text(t) = item { return t.contains("新运行的回答") }
            return false
        } })
    }

    @Test("旧 Run 的展示回调不能覆盖当前 Run 的唯一 phase")
    func staleRunCannotUpdateCurrentPresentation() async throws {
        let (model, coordinator) = makeCoordinator()
        _ = model
        let sessionID = await coordinator.newSession()
        let oldRun = UUID()
        let newRun = UUID()
        coordinator.currentRunID = newRun
        coordinator.beginRunPresentation(runID: newRun, sessionID: sessionID)

        await coordinator.receive(
            AgentChatMessage(role: .assistant, messages: [.toolProgress(step: "正在执行：playback_play_song…")]),
            sessionID: sessionID,
            runID: oldRun
        )
        #expect(coordinator.runPresentationState?.phase == .thinking)

        await coordinator.receive(
            AgentChatMessage(role: .assistant, messages: [.streaming("正在回答")]),
            sessionID: sessionID,
            runID: newRun
        )
        #expect(coordinator.runPresentationState?.phase == .streaming)

        await coordinator.receive(
            AgentChatMessage(role: .assistant, messages: [.toolProgress(step: "正在重试当前批次…")]),
            sessionID: sessionID,
            runID: newRun
        )
        #expect(coordinator.runPresentationState?.phase == .retrying(message: "正在重试当前批次…"))
    }

    @Test("旧 Run 收尾不能释放新 Run 的所有权")
    func oldRunCannotFinishNewRun() async throws {
        let (model, coordinator) = makeCoordinator()
        _ = model
        _ = await coordinator.newSession()
        let oldRun = UUID()
        let newRun = UUID()
        let newLease = ToolExecutionLease(runID: newRun, sessionID: coordinator.activeSessionID!, generation: 2)
        coordinator.currentRunID = newRun
        coordinator.currentExecutionLease = newLease

        coordinator.finishOwnedRun(oldRun)

        #expect(coordinator.currentRunID == newRun)
        #expect(coordinator.currentExecutionLease === newLease)
        #expect(await newLease.isValid())
    }

    @Test("切换会话先撤销旧 Run 的 mutation lease")
    func sessionSwitchRevokesOldMutationLease() async throws {
        let (model, coordinator) = makeCoordinator()
        _ = model
        let a = await coordinator.newSession()
        let b = await coordinator.newSession()
        await coordinator.activate(a)

        let runID = UUID()
        let lease = ToolExecutionLease(runID: runID, sessionID: a, generation: 1)
        coordinator.currentRunID = runID
        coordinator.currentExecutionLease = lease

        await coordinator.activate(b)

        #expect(!lease.isValidSnapshot)
        #expect(coordinator.currentRunID == nil)
        #expect(coordinator.currentExecutionLease == nil)
        #expect(coordinator.activeSessionID == b)
    }

    @Test("TEST E/F：切换会话不污染 UI（activeSessionID 正确、消息按会话隔离）")
    func progressIsolation() async throws {
        let (model, coordinator) = makeCoordinator()
        _ = model
        let a = await coordinator.newSession()
        let b = await coordinator.newSession()
        #expect(coordinator.activeSessionID == b)
        #expect(coordinator.messages.isEmpty)
        await coordinator.activate(a)
        #expect(coordinator.activeSessionID == a)
    }
}

/// 最小连接桩：不做真实网络。
private struct NoopConnector: ServerConnecting {
    func connect(_ input: ServerConnectionInput) async throws -> ServerConnectionResult {
        ServerConnectionResult(
            account: ServerAccount(id: "s1", displayName: "Empty", baseURL: URL(string: "https://empty.test")!, username: "u", credentialReference: "c"),
            capabilities: .init(supportsStructuredLyrics: false),
            artists: [], albums: [], tracks: [], playlists: [],
            serverType: "test", serverVersion: "1.0"
        )
    }
    func restoreLastConnection() async throws -> ServerConnectionResult? { nil }
}
