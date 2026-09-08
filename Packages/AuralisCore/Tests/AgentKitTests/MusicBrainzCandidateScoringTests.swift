// SPDX-License-Identifier: GPL-3.0-only
@testable import AgentKit
import Domain
import Foundation
import LocalCatalog
import Testing

private func scoringTrack(
    title: String,
    artist: String = "Artist A",
    album: String = "Album Name",
    duration: TimeInterval = 200
) -> Track {
    Track(
        id: "scoring-track", serverID: "nas", albumID: "scoring-album", artistID: "scoring-artist",
        title: title, artistName: artist, albumTitle: album, duration: duration
    )
}

private func scoringRecording(
    id: String,
    title: String,
    artists: [String] = ["Artist A"],
    album: String = "Album Name",
    duration: TimeInterval? = 200,
    searchScore: Int = 100
) -> MBRecording {
    MBRecording(
        id: id,
        score: searchScore,
        title: title,
        length: duration.map { Int(($0 * 1_000).rounded()) },
        isrcs: nil,
        artistCredit: artists.map {
            MBArtistCredit(name: $0, artist: MBArtist(id: "artist-\($0)"))
        },
        releases: [
            MBRelease(
                id: "release-\(id)",
                title: album,
                date: nil,
                releaseGroup: MBReleaseGroup(id: "group-\(id)", primaryType: nil)
            ),
        ]
    )
}

@Suite("MusicBrainz Candidate 评分边界")
struct MusicBrainzCandidateScoringTests {
    @Test("核心标题移除软版本年份但保留硬版本词")
    func coreTitleNormalization() {
        #expect(MusicBrainzCandidateScorer.normalizedCoreTitle("Song Name (Remastered 2021)") == "song name")
        #expect(MusicBrainzCandidateScorer.normalizedCoreTitle("Song Name - 2011 Remaster") == "song name")
        #expect(MusicBrainzCandidateScorer.normalizedCoreTitle("Song Name - Remastered Version") == "song name")
        #expect(MusicBrainzCandidateScorer.normalizedCoreTitle("Song Name - 2024 Version") == "song name 2024 version")
        #expect(MusicBrainzCandidateScorer.normalizedCoreTitle("Song Name - Taylor's Version") == "song name taylor s version")
        #expect(MusicBrainzCandidateScorer.normalizedCoreTitle("Song Name - Live") == "song name live")
    }

    @Test("Exact 到明显不同时长的匹配评分矩阵")
    func boundaryMatrix() {
        let matrix: [(String, Track, MBRecording, Bool)] = [
            (
                "Exact",
                scoringTrack(title: "Exact Song"),
                scoringRecording(id: "exact", title: "Exact Song"),
                true
            ),
            (
                "Remaster",
                scoringTrack(title: "Exact Song - 2011 Remaster"),
                scoringRecording(id: "remaster", title: "Exact Song", duration: 203),
                true
            ),
            (
                "Deluxe",
                scoringTrack(title: "Exact Song", album: "Album Name (Deluxe Edition)"),
                scoringRecording(id: "deluxe", title: "Exact Song"),
                true
            ),
            (
                "feat.",
                scoringTrack(title: "Exact Song", artist: "Artist A feat. Artist B"),
                scoringRecording(id: "feat", title: "Exact Song", artists: ["Artist A", "Artist B"]),
                true
            ),
            (
                "missing duration",
                scoringTrack(title: "Exact Song"),
                scoringRecording(id: "missing-duration", title: "Exact Song", duration: nil),
                true
            ),
            (
                "+8 seconds",
                scoringTrack(title: "Exact Song"),
                scoringRecording(id: "plus-eight", title: "Exact Song", duration: 208),
                true
            ),
            (
                "+15 seconds",
                scoringTrack(title: "Exact Song"),
                scoringRecording(id: "plus-fifteen", title: "Exact Song", duration: 215),
                true
            ),
            (
                "Live",
                scoringTrack(title: "Exact Song"),
                scoringRecording(id: "live", title: "Exact Song - Live"),
                false
            ),
            (
                "Acoustic",
                scoringTrack(title: "Exact Song"),
                scoringRecording(id: "acoustic", title: "Exact Song - Acoustic"),
                false
            ),
            (
                "Remix",
                scoringTrack(title: "Exact Song"),
                scoringRecording(id: "remix", title: "Exact Song - Remix"),
                false
            ),
            (
                "Instrumental",
                scoringTrack(title: "Exact Song"),
                scoringRecording(id: "instrumental", title: "Exact Song - Instrumental"),
                false
            ),
            (
                "Cover",
                scoringTrack(title: "Exact Song"),
                scoringRecording(id: "cover", title: "Exact Song - Cover"),
                false
            ),
            (
                "re-recorded",
                scoringTrack(title: "Exact Song - Re-recorded"),
                scoringRecording(id: "re-recorded", title: "Exact Song"),
                false
            ),
            (
                "Taylor's Version",
                scoringTrack(title: "Exact Song - Taylor's Version"),
                scoringRecording(id: "taylors-version", title: "Exact Song"),
                false
            ),
            (
                "2024 Version",
                scoringTrack(title: "Exact Song - 2024 Version"),
                scoringRecording(id: "2024-version", title: "Exact Song"),
                false
            ),
            (
                "重新录制",
                scoringTrack(title: "Exact Song - 重新录制"),
                scoringRecording(id: "rerecorded-cn", title: "Exact Song"),
                false
            ),
            (
                "large duration mismatch",
                scoringTrack(title: "Studio Song", duration: 210),
                scoringRecording(id: "different-duration", title: "Studio Song", duration: 340),
                false
            ),
        ]

        for (name, track, recording, expectedAutoBind) in matrix {
            let score = MusicBrainzCandidateScorer.score(recording: recording, track: track)
            print(
                "MUSIC_BRAINZ_MATCH_MATRIX case=\(name) "
                    + "title=\(String(format: "%.2f", score.titleScore)) "
                    + "artist=\(String(format: "%.2f", score.artistScore)) "
                    + "duration=\(String(format: "%.2f", score.durationScore)) "
                    + "album=\(String(format: "%.2f", score.albumScore)) "
                    + "version_penalty=\(String(format: "%.2f", score.versionPenalty)) "
                    + "confidence=\(String(format: "%.2f", score.confidence)) "
                    + "auto_bind=\(score.confidence >= ExternalMusicIdentity.stableMatchThreshold)"
            )
            #expect(
                (score.confidence >= ExternalMusicIdentity.stableMatchThreshold) == expectedAutoBind,
                "\(name) confidence=\(score.confidence)"
            )
        }

        let live = MusicBrainzCandidateScorer.score(
            recording: scoringRecording(id: "live-guard", title: "Exact Song - Live"),
            track: scoringTrack(title: "Exact Song")
        )
        #expect(live.hardVersionMismatch)
        #expect(live.confidence < ExternalMusicIdentity.stableMatchThreshold)

        let duration = MusicBrainzCandidateScorer.score(
            recording: scoringRecording(id: "duration-guard", title: "Studio Song", duration: 340),
            track: scoringTrack(title: "Studio Song", duration: 210)
        )
        #expect(duration.hardDurationMismatch)
        #expect(duration.confidence <= 0.74)
    }

    @Test("保留 raw confidence 以区分被 clamp 的候选")
    func rawConfidencePreservesWinnerMarginSignal() {
        let track = scoringTrack(title: "Exact Song")
        let best = MusicBrainzCandidateScorer.score(
            recording: scoringRecording(id: "raw-best", title: "Exact Song", searchScore: 100),
            track: track
        )
        let runnerUp = MusicBrainzCandidateScorer.score(
            recording: scoringRecording(id: "raw-runner-up", title: "Exact Song", searchScore: 99),
            track: track
        )

        #expect(best.confidence == 1)
        #expect(runnerUp.confidence == 1)
        #expect(best.rawConfidence > runnerUp.rawConfidence)
        #expect(best.rawConfidence - runnerUp.rawConfidence < MusicBrainzCandidateScorer.minimumWinnerMargin)
    }

    @Test("ISRC 统一正规化并拒绝破损值")
    func isrcNormalization() {
        #expect(ExternalMusicIdentity.normalizedISRC("US-ABC-12-34567") == "USABC1234567")
        #expect(ExternalMusicIdentity.normalizedISRC("usabc1234567") == "USABC1234567")
        #expect(ExternalMusicIdentity.normalizedISRC("broken") == nil)
        #expect(ExternalMusicIdentity.normalizedISRC("USABC1234") == nil)
    }
}
