import Application
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
