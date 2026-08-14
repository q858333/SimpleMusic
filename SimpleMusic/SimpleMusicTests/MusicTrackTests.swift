import XCTest
@testable import SimpleMusic

final class MusicTrackTests: XCTestCase {
    func testUnknownArtistCopyRequiresMusicTrackType() {
        XCTAssertEqual(MusicTrack.unknownArtist, "未知艺人")
    }
}
