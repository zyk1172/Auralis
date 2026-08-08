import Application
import Foundation
import OpenSubsonicKit
import Testing

/// 局域网连接失败时，必须给出「本地网络」权限的可操作指引，
/// 而不是笼统的「网络不可用」。
@Test("URLError to a private LAN host surfaces local-network guidance")
func urlErrorToPrivateHostGuidesLocalNetwork() throws {
    let url = try #require(URL(string: "http://192.168.2.240:3000"))
    let error = URLError(.notConnectedToInternet, userInfo: [NSURLErrorFailingURLErrorKey: url])
    let text = ConnectionErrorDescription.describe(error)
    #expect(text.contains("网络不可用"))
    #expect(text.contains("本地网络"))
    #expect(text.contains("192.168.2.240"))
}

@Test("OpenSubsonic transport error with LAN host surfaces local-network guidance")
func transportErrorWithLanHostGuidesLocalNetwork() {
    let error = OpenSubsonicClientError.transport(code: NSURLErrorNotConnectedToInternet, host: "music.local")
    let text = ConnectionErrorDescription.describe(error)
    #expect(text.contains("本地网络"))
    #expect(text.contains("music.local"))
}

@Test("Transport error without a host keeps a generic message")
func transportErrorWithoutHostStaysGeneric() {
    let error = OpenSubsonicClientError.transport(code: NSURLErrorNotConnectedToInternet, host: nil)
    let text = ConnectionErrorDescription.describe(error)
    #expect(text == "网络不可用，请检查网络连接")
}

@Test("Transport error to a public host does not claim local-network denial")
func transportErrorToPublicHostStaysGeneric() {
    let error = OpenSubsonicClientError.transport(code: NSURLErrorNotConnectedToInternet, host: "music.example.test")
    let text = ConnectionErrorDescription.describe(error)
    #expect(text == "网络不可用，请检查网络连接")
    #expect(!text.contains("本地网络"))
}

@Test("Cannot-connect-to-host error to LAN host is actionable")
func cannotConnectToLanHostIsActionable() {
    let url = URL(string: "http://192.168.2.240:3000")!
    let error = URLError(.cannotConnectToHost, userInfo: [NSURLErrorFailingURLErrorKey: url])
    let text = ConnectionErrorDescription.describe(error)
    #expect(text.contains("无法连接到服务器"))
    #expect(text.contains("本地网络"))
}
