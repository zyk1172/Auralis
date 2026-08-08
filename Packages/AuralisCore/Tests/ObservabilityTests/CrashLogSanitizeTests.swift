import Observability
import Testing

@Suite("CrashLog 脱敏")
struct CrashLogSanitizeTests {
    @Test("查询串认证参数被替换为 <redacted>")
    func redactsAuthQueryParameters() {
        let url = "http://nas.local/rest/stream?id=1&u=alice&t=deadbeef&s=abcd1234&v=1.16.1&c=Auralis&apikey=secret-key&p=plainpass"
        let cleaned = CrashLog.sanitize(url)
        #expect(!cleaned.contains("deadbeef"))
        #expect(!cleaned.contains("secret-key"))
        #expect(!cleaned.contains("plainpass"))
        #expect(cleaned.contains("t=<redacted>"))
        #expect(cleaned.contains("apikey=<redacted>"))
        #expect(cleaned.contains("p=<redacted>"))
        // 保留非敏感参数
        #expect(cleaned.contains("id=1"))
        #expect(cleaned.contains("v=1.16.1"))
    }

    @Test("Authorization 头被替换")
    func redactsAuthHeader() {
        let line = "Authorization: Bearer abc.def.ghi"
        let cleaned = CrashLog.sanitize(line)
        #expect(!cleaned.contains("abc.def.ghi"))
        #expect(cleaned.contains("Authorization: <redacted>"))
    }

    @Test("普通日志不受影响")
    func keepsPlainLogs() {
        let line = "AVFoundationPlaybackEngine.play 开始: 七里香"
        #expect(CrashLog.sanitize(line) == line)
    }
}

extension CrashLogSanitizeTests {
    @Test("URL userinfo 内嵌密码被替换")
    func redactsURLUserinfo() {
        let url = "http://alice:secret123@nas.local:4533/rest/ping"
        let cleaned = CrashLog.sanitize(url)
        #expect(!cleaned.contains("secret123"))
        #expect(!cleaned.contains("alice:secret123"))
        #expect(cleaned.contains("<redacted>@nas.local"))
    }

    @Test("大写认证参数名同样被替换（大小写不敏感）")
    func redactsUppercaseAuthQueryParameters() {
        let url = "http://nas.local/rest/stream?id=1&U=alice&T=deadbeef&S=salt&APIKEY=secret-key"
        let cleaned = CrashLog.sanitize(url)
        #expect(!cleaned.contains("deadbeef"))
        #expect(!cleaned.contains("secret-key"))
        #expect(cleaned.contains("T=<redacted>"))
        #expect(cleaned.contains("APIKEY=<redacted>"))
    }
}
