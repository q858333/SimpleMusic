import XCTest
@testable import SimpleMusic

@MainActor
final class LocalMusicStoreTests: XCTestCase {
    func testInsertFetchAndDeleteDownloadedTrack() throws {
        let store = try LocalMusicStore.inMemory()
        let metadata = DownloadedTrackMetadata(
            id: "one",
            fileName: "one.mp3",
            title: "One",
            artist: "A",
            album: "B",
            duration: 12
        )

        let inserted = try store.insert(metadata)

        XCTAssertEqual(inserted.id, "one")
        XCTAssertEqual(inserted.title, "One")
        XCTAssertEqual(inserted.artist, "A")
        XCTAssertEqual(inserted.album, "B")
        XCTAssertEqual(inserted.duration, 12)
        XCTAssertEqual(inserted.source, .downloaded(fileName: "one.mp3"))
        XCTAssertEqual(try store.fetchTracks().map(\.id), ["one"])

        try store.delete(id: "one")

        XCTAssertTrue(try store.fetchTracks().isEmpty)
    }
}
