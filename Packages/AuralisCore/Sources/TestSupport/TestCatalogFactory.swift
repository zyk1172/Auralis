import Domain
import Foundation

/// 测试专用的确定性音乐库生成器。只服务于单元测试与预览，不出现在生产 UI。
public enum TestCatalogFactory {
    public static func make() -> LibraryCatalog {
        let serverID: ServerID = "test-server"
        let artistNames = [
            "岚屿", "Northbound", "Mira Vale", "云际合奏团", "Serein", "Kite Theory",
            "林间信号", "Lumen Coast", "Nocturne Field", "朝雾", "Glass Harbor", "白昼电台",
            "Aster Echo", "青黛", "Quiet Assembly", "Circuit Bloom", "远山", "Solenne",
            "橙海", "Paper Satellites",
        ]
        let albumNames = [
            "潮汐备忘录", "Afterglow Transit", "雾中来信", "Low Light Rooms", "星港慢行",
            "Soft Geometry", "雨落之前", "Night Bus Atlas", "庭院与风", "Static Gardens",
            "白噪之间", "Northern Windows", "午夜航线", "Paper Moon", "未寄出的夏天",
            "Blue Hour", "群山回声", "Velvet Signal", "城市睡眠", "Quiet Machines",
            "海岸频率", "Sepia Current", "无人电台", "Moss and Glass", "灯火渐远",
            "Parallel Dawn", "深夜植物园", "Warm Circuits", "冬日光谱", "Aerial Letters",
        ]
        let genreNames = ["Ambient", "Alternative", "Classical", "Electronic", "Jazz", "Neo Soul", "Pop", "Post Rock"]
        let languages = ["zh-Hans", "en", "ja", "instrumental"]
        let artists = artistNames.enumerated().map { index, name in
            Artist(
                id: ArtistID(rawValue: "test-artist-\(index + 1)"),
                serverID: serverID,
                name: name,
                albumCount: index < 10 ? 2 : 1,
                artworkKey: "artist-\(index + 1)"
            )
        }
        let albums = albumNames.enumerated().map { index, title in
            let artist = artists[index % artists.count]
            return Album(
                id: AlbumID(rawValue: "test-album-\(index + 1)"),
                serverID: serverID,
                artistID: artist.id,
                title: title,
                artistName: artist.name,
                year: 1998 + (index % 27),
                genre: genreNames[index % genreNames.count],
                artworkKey: "album-\(index + 1)"
            )
        }
        let tracks = (0..<200).map { index in
            let album = albums[index % albums.count]
            let titleStem = ["远航", "薄暮", "回声", "灯塔", "慢车", "雨幕", "晨雾", "无眠"][index % 8]
            return Track(
                id: TrackID(rawValue: "test-track-\(index + 1)"),
                serverID: serverID,
                albumID: album.id,
                artistID: album.artistID,
                title: "\(titleStem) \(String(format: "%03d", index + 1))",
                artistName: album.artistName,
                albumTitle: album.title,
                duration: TimeInterval(152 + ((index * 37) % 246)),
                trackNumber: (index % 12) + 1,
                discNumber: (index % 29 == 0) ? 2 : 1,
                year: album.year,
                genres: [album.genre ?? "Unknown"],
                language: languages[index % languages.count],
                isFavorite: index % 7 == 0,
                rating: index % 7 == 0 ? 4 + (index % 2) : nil,
                artworkKey: album.artworkKey,
                sourceInfo: AudioSourceInfo(
                    codec: index % 3 == 0 ? "FLAC" : "AAC",
                    bitDepth: index % 3 == 0 ? 24 : 16,
                    sampleRate: index % 5 == 0 ? 96_000 : 44_100,
                    bitRate: index % 3 == 0 ? 2_854_000 : 256_000,
                    channelCount: 2
                )
            )
        }
        let history = tracks.prefix(48).enumerated().map { index, track in
            PlayHistory(
                id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 1)) ?? UUID(),
                trackID: track.id,
                playedAt: Date(timeIntervalSince1970: 1_735_689_600 - Double(index * 86_400)),
                completionRatio: index % 5 == 0 ? 0.18 : 0.96,
                wasSkipped: index % 5 == 0
            )
        }
        let downloads = tracks.prefix(26).enumerated().map { index, track in
            DownloadRecord(
                trackID: track.id,
                status: index < 20 ? .downloaded : .downloading,
                progress: index < 20 ? 1 : Double(index - 19) / 7,
                byteCount: Int64(8_000_000 + index * 420_000)
            )
        }
        let lyricLines = [
            "风从海岸慢慢经过", "城市把灯光留在身后", "我们在安静的频率里", "听见遥远而清晰的回声",
            "夜色没有催促答案", "只让每一步变得温柔", "当最后一班列车离开", "音乐仍替我们停留",
        ].enumerated().map { index, text in
            TimedLyricLine(
                id: UUID(uuidString: String(format: "10000000-0000-0000-0000-%012d", index + 1)) ?? UUID(),
                startTime: Double(index * 16),
                text: text,
                translation: nil
            )
        }
        let lyrics = Dictionary(uniqueKeysWithValues: tracks.prefix(40).map { track in
            (track.id, LyricsDocument(trackID: track.id, language: track.language, lines: lyricLines, isSynced: true))
        })
        let recommendations = [
            RecommendationResult(
                id: UUID(uuidString: "20000000-0000-0000-0000-000000000001") ?? UUID(),
                title: "深夜独处 · 华语 · 低能量",
                explanation: "从测试音乐库中筛选了低能量、较少重复的华语曲目，并限制同一艺人的连续出现。",
                trackIDs: Array(tracks.filter { $0.language == "zh-Hans" }.prefix(18).map(\.id)),
                filters: ["深夜", "华语", "低能量"]
            ),
            RecommendationResult(
                id: UUID(uuidString: "20000000-0000-0000-0000-000000000002") ?? UUID(),
                title: "从平静到有力量",
                explanation: "按能量曲线渐进排列，所有条目都对应当前音乐库中的真实 Track ID。",
                trackIDs: Array(tracks[40..<56].map(\.id)),
                filters: ["渐进", "多样性", "约 1 小时"]
            ),
        ]
        let playlists = [
            Playlist(id: "test-playlist-1", serverID: serverID, name: "深夜电台", trackIDs: recommendations[0].trackIDs, comment: "测试策展结果"),
            Playlist(id: "test-playlist-2", serverID: serverID, name: "周末慢行", trackIDs: Array(tracks[80..<98].map(\.id))),
        ]
        let genres = genreNames.map { name in
            Genre(name: name, songCount: tracks.filter { $0.genres.contains(name) }.count)
        }
        return LibraryCatalog(
            account: ServerAccount(id: serverID, displayName: "Test Library"),
            artists: artists,
            albums: albums,
            tracks: tracks,
            genres: genres,
            playlists: playlists,
            history: history,
            downloads: downloads,
            lyrics: lyrics,
            recommendations: recommendations
        )
    }
}
