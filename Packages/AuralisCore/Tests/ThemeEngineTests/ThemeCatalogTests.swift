import Foundation
import Testing
import ThemeEngine

@Suite("Built-in theme catalog")
@MainActor
struct ThemeCatalogTests {
    @Test("主题 ID、名称与视觉结构不重复")
    func themeIdentitiesAndVisualLanguagesAreDistinct() {
        let themes = BuiltInThemes.all
        #expect(Set(themes.map(\.id)).count == themes.count)
        #expect(Set(themes.map(\.name)).count == themes.count)

        let signatures = themes.map { theme in
            [
                theme.colorScheme == .dark ? "dark" : "light",
                theme.materials.navigation.rawValue,
                theme.artworkStyle.rawValue,
                theme.visualizer.rawValue,
            ].joined(separator: "|")
        }
        #expect(Set(signatures).count == themes.count)
    }

    @Test("合并主题 ID 全部映射到仍存在的主题")
    func legacyMappingsResolveToVisibleThemes() {
        let visibleIDs = Set(BuiltInThemes.all.map(\.id))
        for (legacyID, canonicalID) in BuiltInThemes.legacyIDMappings {
            #expect(!visibleIDs.contains(legacyID), "旧主题 \(legacyID) 不应继续重复展示")
            #expect(visibleIDs.contains(canonicalID), "旧主题 \(legacyID) 的迁移目标不存在")
            #expect(BuiltInThemes.canonicalID(for: legacyID) == canonicalID)
        }
    }

    @Test("ThemeStore 启动时迁移旧选择并持久化")
    func storeMigratesPersistedLegacySelection() {
        let suite = "ThemeCatalogTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("cyber-pulse", forKey: "auralis.selected-theme")

        let store = ThemeStore(defaults: defaults)

        #expect(store.selectedID == "neon-city")
        #expect(store.current.id == "neon-city")
        #expect(defaults.string(forKey: "auralis.selected-theme") == "neon-city")
    }

    @Test("旧备份通过 select 也会迁移，未知 ID 不覆盖当前选择")
    func selectionAcceptsLegacyBackupIDs() {
        let suite = "ThemeCatalogTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ThemeStore(defaults: defaults)

        store.select(id: "midnight")
        #expect(store.selectedID == "midnight-oled")
        #expect(defaults.string(forKey: "auralis.selected-theme") == "midnight-oled")

        store.select(id: "theme-that-does-not-exist")
        #expect(store.selectedID == "midnight-oled")
    }

    @Test("新增主题覆盖暖色、冷色玻璃与深绿实体三种语言")
    func expandedCatalogContainsNewVisualFamilies() {
        let ids = Set(BuiltInThemes.all.map(\.id))
        #expect(ids.isSuperset(of: ["solar-studio", "polar-frost", "forest-terminal"]))
    }
}
