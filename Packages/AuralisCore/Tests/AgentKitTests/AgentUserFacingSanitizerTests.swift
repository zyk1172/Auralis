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
        #expect(output.contains("[内部标识]"))
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
