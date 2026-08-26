@testable import AgentKit
import Domain
import Foundation
import LocalCatalog
import Testing

struct AgentUserFacingSanitizerTests {
    @Test("User prose redacts internal IDs without hiding ordinary names")
    func sanitizesInternalIdentifiers() {
        let input = "歌单（playlistID=server-a:123，18 首，时长 12:34）；GlobalID(server-b:456)；server-c:789；id=normal-name"
        let output = AgentUserFacingSanitizer.text(input)
        #expect(!output.contains("server-a"))
        #expect(!output.contains("server-b"))
        #expect(!output.contains("server-c"))
        #expect(output.contains("18 首"))
        #expect(output.contains("12:34"))
        #expect(output.contains("id=normal-name"))
        #expect(output.contains("[内部标识]"))
    }

    @Test("Ordinary technical id and uuid values are preserved")
    func preservesOrdinaryTechnicalIdentifiers() {
        let input = #"HTML: <div id="main">；API 参数 id=user_123；数据库 id=42；uuid=550e8400-e29b-41d4-a716-446655440000"#
        #expect(AgentUserFacingSanitizer.text(input) == input)
    }

    @Test("Entity and server labels redact only semantic Auralis identifiers")
    func entityLabelsRequireGlobalIDShape() {
        let input = "playlistID=server-a:123；trackID=server-a:456；albumID=not-an-id；serverID=server-a；serverID=main"
        let output = AgentUserFacingSanitizer.text(input)
        #expect(!output.contains("playlistID=server-a:123"))
        #expect(!output.contains("trackID=server-a:456"))
        #expect(output.contains("albumID=not-an-id"))
        #expect(!output.contains("serverID=server-a"))
        #expect(!output.contains("serverID=main"))
    }

    @Test("Quoted and JSON-style labels redact their parsed values")
    func quotedAndJSONLabelsAreSanitized() {
        let input = #"serverID="internal"; "serverID":"opaque-server"; playlistID="xxx:123"; "trackID":"srv:456" id="main""#
        let output = AgentUserFacingSanitizer.text(input)

        #expect(!output.contains("internal"))
        #expect(!output.contains("opaque-server"))
        #expect(!output.contains("xxx:123"))
        #expect(!output.contains("srv:456"))
        #expect(output.contains("id=\"main\""))
        #expect(output.contains("[内部标识]"))
        #expect(!output.contains("serverID="))
        #expect(output.contains(#""serverID":"[内部标识]"#))
    }

    @Test("Only valid GlobalID call syntax is redacted")
    func invalidGlobalIDCallIsPreserved() {
        let input = "GlobalID(foo)；data-trackID=\"server-a:1\"；trackID=server-a:1"
        let output = AgentUserFacingSanitizer.text(input)
        #expect(output.contains("GlobalID(foo)"))
        #expect(output.contains(#"data-trackID="server-a:1""#))
        #expect(!output.contains("trackID=server-a:1"))
    }

    @Test("User-authored identifiers remain verbatim")
    func preservesUserAuthoredMessage() {
        let message = AgentChatMessage(
            role: .user,
            messages: [.text("playlistID=server-a:123 id=user_123 uuid=550e8400-e29b-41d4-a716-446655440000")]
        )
        let sanitized = AgentUserFacingSanitizer.chatMessage(message)
        #expect(sanitized.role == .user)
        guard case let .text(value) = sanitized.messages.first else {
            Issue.record("expected the user text message to remain text")
            return
        }
        #expect(value == "playlistID=server-a:123 id=user_123 uuid=550e8400-e29b-41d4-a716-446655440000")
    }

    @Test("Confirmation text is sanitized while the exact call is preserved")
    func sanitizesConfirmationButPreservesCall() throws {
        let gid = GlobalID(serverID: "server-a", remoteID: "123")
        let pending = PendingConfirmation(
            runID: UUID(),
            sessionID: UUID(),
            toolName: "playlist_delete",
            permission: .destructive,
            operation: .playlistDelete,
            reason: "参数：playlistID=\(gid.description)",
            title: "删除 server-a:123？",
            detail: "playlistID=\(gid.description)",
            call: ToolCall(name: "playlist_delete", arguments: ["playlistID": .string(gid.description)])
        )
        let sanitized = AgentUserFacingSanitizer.confirmation(pending)
        #expect(!sanitized.title.contains(gid.description))
        #expect(!sanitized.detail.contains(gid.description))
        #expect(sanitized.call.stringArguments["playlistID"] == gid.description)
    }

    @Test("Playlist and artist cards keep model IDs but expose no ID payload field to UI text")
    func structuredCardsSeparateModelAndUserProjections() throws {
        let playlist = PlaylistCard(globalID: GlobalID(serverID: "srv", remoteID: "pl"), name: "通勤", trackCount: 18, isReadOnly: false)
        let artist = ArtistCard(globalID: GlobalID(serverID: "srv", remoteID: "ar"), name: "周杰伦", albumCount: 12)
        let modelText = ToolLoop.messageTextForModel(.playlistCards([playlist]))
        #expect(modelText.contains("通勤"))
        #expect(modelText.contains("playlistID=srv:pl"))

        let encoder = JSONEncoder()
        let playlistData = try encoder.encode(AgentChatMessage(role: .assistant, messages: [.playlistCards([playlist])]))
        let artistData = try encoder.encode(AgentChatMessage(role: .assistant, messages: [.artistCards([artist])]))
        #expect(String(decoding: playlistData, as: UTF8.self).contains("playlistCards"))
        #expect(String(decoding: artistData, as: UTF8.self).contains("artistCards"))
    }
}
