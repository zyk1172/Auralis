import Application
import Domain
import Foundation
import Testing

@Test("HTTPS servers are accepted")
func acceptsHTTPS() throws {
    let url = try #require(URL(string: "https://music.example.test"))
    try ServerURLPolicy.validate(url)
}

@Test("HTTP is limited to local and private network hosts", arguments: [
    "http://localhost:4533",
    "http://music.local:4533",
    "http://127.0.0.1:4533",
    "http://10.20.30.40:4533",
    "http://172.16.0.5:4533",
    "http://172.31.255.254:4533",
    "http://192.168.50.5:4533",
])
func acceptsPrivateHTTP(value: String) throws {
    let url = try #require(URL(string: value))
    try ServerURLPolicy.validate(url)
}

@Test("Public HTTP is rejected")
func rejectsPublicHTTP() throws {
    let url = try #require(URL(string: "http://music.example.test"))
    #expect(throws: ServerConnectionError.insecurePublicServer) {
        try ServerURLPolicy.validate(url)
    }
}

@Test("URL 内嵌 user:pass@ 被拒绝（凭据不得随地址落库）")
func rejectsEmbeddedCredentials() throws {
    let url = try #require(URL(string: "http://alice:secret@nas.local:4533"))
    #expect(throws: ServerConnectionError.embeddedCredentials) {
        try ServerURLPolicy.validate(url)
    }
}

@Test("HTTPS 内嵌凭据同样被拒绝")
func rejectsEmbeddedCredentialsOnHTTPS() throws {
    let url = try #require(URL(string: "https://alice:secret@music.example.test"))
    #expect(throws: ServerConnectionError.embeddedCredentials) {
        try ServerURLPolicy.validate(url)
    }
}

// MARK: - R07：IPv6 私网/本机分类（NetworkHostClassifier）

@Test("IPv6 ULA / link-local / loopback / IPv4-mapped 被判定为私网", arguments: [
    "fc00::1",        // ULA fc00::/7
    "fd12:3456::1",   // ULA fd00::/7
    "fe80::1",        // link-local fe80::/10
    "fe80::1%en0",    // link-local + zone identifier
    "::1",            // IPv6 loopback
    "::ffff:192.168.1.5", // IPv4-mapped 私网
])
func ipv6PrivateHostsAreClassifiedPrivate(host: String) {
    #expect(NetworkHostClassifier.isPrivateOrLocal(host: host) == true, "\(host) 应判定为私网")
}

@Test("IPv6 公网地址被判定为非私网", arguments: [
    "2001:db8::1",    // 文档用公网段
    "2606:4700::1111", // Cloudflare 公网
    "2a00:1450:4001::1", // 公网
])
func ipv6PublicHostsAreClassifiedPublic(host: String) {
    #expect(NetworkHostClassifier.isPrivateOrLocal(host: host) == false, "\(host) 不应判定为私网")
}

@Test("HTTP + IPv6 私网地址通过 ServerURLPolicy 校验")
func acceptsPrivateHTTPIPv6() throws {
    let url = try #require(URL(string: "http://[fe80::1%en0]:4533"))
    try ServerURLPolicy.validate(url)
}
