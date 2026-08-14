import Foundation
import XCTest
@testable import SimpleMusic

final class DownloadFileStoreTests: XCTestCase {
    func testDuplicateNamesProduceDifferentDestinations() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DownloadFileStore(rootURL: root)
        let first = store.destinationURL(suggestedName: "song.mp3")

        try Data().write(to: first)

        XCTAssertNotEqual(first, store.destinationURL(suggestedName: "song.mp3"))
    }

    func testSanitizesSuggestedNameIntoStoreRoot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DownloadFileStore(rootURL: root)

        let destination = store.destinationURL(suggestedName: "../../song.mp3")

        XCTAssertEqual(destination.deletingLastPathComponent().standardizedFileURL, root.standardizedFileURL)
        XCTAssertFalse(destination.lastPathComponent.contains("/"))
        XCTAssertEqual(destination.pathExtension, "mp3")
    }
}
