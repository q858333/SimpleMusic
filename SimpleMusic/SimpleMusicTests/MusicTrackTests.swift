import XCTest
@testable import SimpleMusic

final class MusicTrackTests: XCTestCase {
    func testUnknownArtistCopyRequiresMusicTrackType() {
        XCTAssertEqual(MusicTrack.unknownArtist, L10n.text("track.unknown_artist"))
        XCTAssertEqual(MusicTrack.unknownAlbum, L10n.text("track.unknown_album"))
    }

    func testDownloadedTrackKeepsStableIdentity() {
        let track = MusicTrack(id: "local-1", title: "歌", artist: "艺人", album: "专辑", duration: 61, artworkData: nil, source: .downloaded(fileName: "local-1.m4a"))

        XCTAssertEqual(track.id, "local-1")
        XCTAssertEqual(track.source, .downloaded(fileName: "local-1.m4a"))
    }
}
