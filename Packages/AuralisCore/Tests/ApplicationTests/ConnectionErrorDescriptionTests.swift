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
    // 行为不变式（不依赖具体语言）：本地地址 → 必须带「本地网络」排查指引并包含主机。
    #expect(text.contains("192.168.2.240"))
    #expect(text.lowercased().contains("local network") || text.contains("本地网络"))
}

@Test("OpenSubsonic transport error with LAN host surfaces local-network guidance")
func transportErrorWithLanHostGuidesLocalNetwork() {
    let error = OpenSubsonicClientError.transport(code: NSURLErrorNotConnectedToInternet, host: "music.local")
    let text = ConnectionErrorDescription.describe(error)
    #expect(text.contains("music.local"))
    #expect(text.lowercased().contains("local network") || text.contains("本地网络"))
}

@Test("Transport error without a host keeps a generic message")
func transportErrorWithoutHostStaysGeneric() {
    let error = OpenSubsonicClientError.transport(code: NSURLErrorNotConnectedToInternet, host: nil)
    let text = ConnectionErrorDescription.describe(error)
    #expect(text.lowercased().contains("network") || text.contains("网络"))
    #expect(!(text.lowercased().contains("local network") || text.contains("本地网络")))
}

@Test("Transport error to a public host does not claim local-network denial")
func transportErrorToPublicHostStaysGeneric() {
    let error = OpenSubsonicClientError.transport(code: NSURLErrorNotConnectedToInternet, host: "music.example.test")
    let text = ConnectionErrorDescription.describe(error)
    #expect(text.lowercased().contains("network") || text.contains("网络"))
    #expect(!(text.lowercased().contains("local network") || text.contains("本地网络")))
}

@Test("Cannot-connect-to-host error to LAN host is actionable")
func cannotConnectToLanHostIsActionable() {
    let url = URL(string: "http://192.168.2.240:3000")!
    let error = URLError(.cannotConnectToHost, userInfo: [NSURLErrorFailingURLErrorKey: url])
    let text = ConnectionErrorDescription.describe(error)
    #expect(text.contains("192.168.2.240"))
    #expect(text.lowercased().contains("local network") || text.contains("本地网络"))
}
