import Domain

public enum Fixtures {
    public static let catalog = TestCatalogFactory.make()
    public static var track: Track { catalog.tracks[0] }
    public static var secondTrack: Track { catalog.tracks[1] }
}
