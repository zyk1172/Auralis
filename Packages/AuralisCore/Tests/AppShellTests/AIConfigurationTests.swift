@testable import AppShell
import AIKit
import Foundation
import Testing

// MARK: - AI 接口配置健壮性

/// 漏写协议的 Base URL（如 `api.deepseek.com`）也应判定为配置完整，
/// 否则用户填了国内模型却一直停在「本地模式」。
@Test("漏写协议的 Base URL 仍判定为配置完整")
func schemeLessHostIsComplete() throws {
    let defaults = try #require(UserDefaults(suiteName: "auralis-ai-config-test-\(UUID())"))
    defaults.set("api.deepseek.com", forKey: AIConnectionSettings.Keys.baseURL)
    defaults.set("/v1/chat/completions", forKey: AIConnectionSettings.Keys.apiPath)
    defaults.set("deepseek-chat", forKey: AIConnectionSettings.Keys.model)
    let settings = AIConnectionSettings(defaults: defaults)
    #expect(settings.isComplete)
    #expect(settings.makeProvider() != nil)
    #expect(settings.completenessError == nil)
}

/// 本地模型常写成 `localhost:11434`，漏写 http 也应判定完整并推断为 http。
@Test("localhost 漏写 http 仍判定为完整且推断为 http")
func localhostWithoutSchemeIsComplete() throws {
    let defaults = try #require(UserDefaults(suiteName: "auralis-ai-config-test-\(UUID())"))
    defaults.set("localhost:11434", forKey: AIConnectionSettings.Keys.baseURL)
    defaults.set("llama3", forKey: AIConnectionSettings.Keys.model)
    let settings = AIConnectionSettings(defaults: defaults)
    #expect(settings.isComplete)
    #expect(settings.makeProvider() != nil)
    #expect(settings.completenessError == nil)
}

/// 模型为空时配置不完整，并给出可读原因。
@Test("模型为空判定为不完整并给出原因")
func emptyModelIsIncomplete() throws {
    let defaults = try #require(UserDefaults(suiteName: "auralis-ai-config-test-\(UUID())"))
    defaults.set("https://api.deepseek.com", forKey: AIConnectionSettings.Keys.baseURL)
    defaults.set("", forKey: AIConnectionSettings.Keys.model)
    let settings = AIConnectionSettings(defaults: defaults)
    #expect(!settings.isComplete)
    #expect(settings.completenessError != nil)
}

/// 完全空白配置应判定为不完整。
@Test("空白配置判定为不完整")
func blankConfigIsIncomplete() throws {
    let defaults = try #require(UserDefaults(suiteName: "auralis-ai-config-test-\(UUID())"))
    defaults.set("", forKey: AIConnectionSettings.Keys.baseURL)
    defaults.set("", forKey: AIConnectionSettings.Keys.model)
    let settings = AIConnectionSettings(defaults: defaults)
    #expect(!settings.isComplete)
    #expect(settings.completenessError != nil)
}
