#if os(macOS)
import Foundation
import SwiftUI

/// 资料库 Sidebar 显示偏好：显示/隐藏 + 拖动排序，持久化到 UserDefaults。
@MainActor
final class MacSidebarPreferences: ObservableObject {
    static let storageKey = "auralis.mac.sidebar.library"

    struct Item: Codable, Identifiable, Hashable {
        var id: String
        var title: String
        var symbol: String
        var enabled: Bool
    }

    @Published var items: [Item] {
        didSet { persist() }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([Item].self, from: data),
           !decoded.isEmpty {
            self.items = decoded
        } else {
            self.items = Self.defaultItems
        }
    }

    private let defaults: UserDefaults

    private static let defaultItems: [Item] = [
        Item(id: MacSidebarDestination.recentlyAdded.rawValue, title: String(localized: "最近添加", bundle: .module), symbol: "tray.and.arrow.down", enabled: true),
        Item(id: MacSidebarDestination.artists.rawValue, title: String(localized: "艺术家", bundle: .module), symbol: "person.2", enabled: true),
        Item(id: MacSidebarDestination.albums.rawValue, title: String(localized: "专辑", bundle: .module), symbol: "square.stack", enabled: true),
        Item(id: MacSidebarDestination.songs.rawValue, title: String(localized: "歌曲", bundle: .module), symbol: "music.note", enabled: true),
        Item(id: MacSidebarDestination.genres.rawValue, title: String(localized: "流派", bundle: .module), symbol: "music.quarternote.3", enabled: true),
        Item(id: MacSidebarDestination.downloads.rawValue, title: String(localized: "下载", bundle: .module), symbol: "arrow.down.circle", enabled: true),
        Item(id: MacSidebarDestination.recentlyPlayed.rawValue, title: String(localized: "最近播放", bundle: .module), symbol: "clock", enabled: true)
    ]

    /// 当前启用的资料库目的地（按用户排序）。
    var enabledDestinations: [MacSidebarDestination] {
        items.filter(\.enabled).compactMap { item in
            MacSidebarDestination(rawValue: item.id)
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(items) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }

    func move(fromOffsets: IndexSet, toOffset: Int) {
        items.move(fromOffsets: fromOffsets, toOffset: toOffset)
    }

    func toggle(_ id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].enabled.toggle()
    }
}

/// 资料库编辑面板：显示/隐藏 + 拖动排序。
struct MacSidebarLibraryEditor: View {
    @ObservedObject var prefs: MacSidebarPreferences

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "资料库", bundle: .module))
                .font(.headline)
            List {
                ForEach($prefs.items) { $item in
                    Toggle(isOn: $item.enabled) {
                        Label(item.title, systemImage: item.symbol)
                    }
                }
                .onMove { from, to in
                    prefs.move(fromOffsets: from, toOffset: to)
                }
            }
            .listStyle(.inset)
            .frame(width: 220, height: 240)
        }
        .padding(12)
    }
}
#endif
