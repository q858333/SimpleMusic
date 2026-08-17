import XCTest
@testable import SimpleMusic

final class MusicLibraryServiceMappingTests: XCTestCase {
    /// 如果映射不再为缺失元数据提供可展示的默认值，此测试应失败。
    @MainActor
    func testMissingMetadataUsesSystemIdentifierAndUnknownCopy() {
        let track = MusicLibraryService.makeTrack(from: .init(
            persistentID: 42,
            title: nil,
            artist: nil,
            album: nil,
            duration: 8,
            artworkData: nil
        ))

        XCTAssertEqual(track.id, "system-42")
        XCTAssertEqual(track.title, "system-42")
        XCTAssertEqual(track.artist, MusicTrack.unknownArtist)
        XCTAssertEqual(track.album, MusicTrack.unknownAlbum)
        XCTAssertEqual(track.duration, 8)
        XCTAssertEqual(track.source, .system(persistentID: 42))
    }

    /// 如果系统音乐已有元数据却被默认文案覆盖，此测试应失败。
    @MainActor
    func testMetadataKeepsSystemMusicValues() {
        let track = MusicLibraryService.makeTrack(from: .init(
            persistentID: 7,
            title: "系统歌曲",
            artist: "系统艺人",
            album: "系统专辑",
            duration: 61,
            artworkData: Data([0x01])
        ))

        XCTAssertEqual(track.id, "system-7")
        XCTAssertEqual(track.title, "系统歌曲")
        XCTAssertEqual(track.artist, "系统艺人")
        XCTAssertEqual(track.album, "系统专辑")
        XCTAssertEqual(track.duration, 61)
        XCTAssertEqual(track.artworkData, Data([0x01]))
        XCTAssertEqual(track.source, .system(persistentID: 7))
    }
}
