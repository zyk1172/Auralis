// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// Canonical Recommendation Index transport format. It remains JSON.
    static var auralisRecommendationIndex: UTType {
        UTType(exportedAs: "com.auralis.player.recommendation-index", conformingTo: .json)
    }

    /// Pre-release exported files remain importable. New exports use the
    /// canonical identifier above.
    static var auralisLegacyRecommendationIndex: UTType {
        UTType(importedAs: "com.auralis.player.index-v2", conformingTo: .json)
    }
}

/// 系统文件导出/导入使用的推荐索引文档包装。只承载纯分类派生数据 JSON，
/// 不包含任何服务器凭据、播放地址或私人播放数据。
struct RecommendationIndexIndexFile: FileDocument {
    static var readableContentTypes: [UTType] { [.auralisRecommendationIndex, .auralisLegacyRecommendationIndex] }

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
