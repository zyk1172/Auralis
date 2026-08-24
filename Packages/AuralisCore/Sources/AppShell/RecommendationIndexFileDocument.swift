import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// `.auralis-index-v2` 推荐索引传输格式。初版为 JSON 文本。
    static var auralisIndexV2: UTType {
        UTType(exportedAs: "com.auralis.player.index-v2", conformingTo: .json)
    }
}

/// 系统文件导出/导入使用的 V2 索引文档包装。只承载纯分类派生数据 JSON，
/// 不包含任何服务器凭据、播放地址或私人播放数据。
struct RecommendationIndexV2IndexFile: FileDocument {
    static var readableContentTypes: [UTType] { [.auralisIndexV2] }

    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}