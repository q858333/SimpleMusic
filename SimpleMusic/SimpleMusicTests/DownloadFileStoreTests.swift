import Foundation
import XCTest
@testable import SimpleMusic

final class DownloadFileStoreTests: XCTestCase {
    func testConcurrentReservationsProduceThreeDifferentDestinations() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DownloadFileStore(rootURL: root)
        let lock = NSLock()
        var destinations = [URL]()

        DispatchQueue.concurrentPerform(iterations: 3) { _ in
            let destination = try! store.destinationURL(suggestedName: "song.mp3")
            lock.lock()
            destinations.append(destination)
            lock.unlock()
        }

        XCTAssertEqual(Set(destinations).count, 3)
        XCTAssertTrue(destinations.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    }

    func testSanitizesSuggestedNameIntoStoreRoot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DownloadFileStore(rootURL: root)

        let destination = try store.destinationURL(suggestedName: "../../song.mp3")

        XCTAssertEqual(destination.deletingLastPathComponent().standardizedFileURL, root.standardizedFileURL)
        XCTAssertFalse(destination.lastPathComponent.contains("/"))
        XCTAssertEqual(destination.pathExtension, "mp3")
    }

    func testNormalizesEmptySeparatorAndIllegalSuggestedNames() throws {
        let cases = [("", "audio"), ("   ", "audio"), ("/", "audio"), ("//", "audio"), ("bad:name?.mp3", "bad_name_.mp3")]

        for (suggestedName, expectedName) in cases {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let store = try DownloadFileStore(rootURL: root)

            XCTAssertEqual(try store.destinationURL(suggestedName: suggestedName).lastPathComponent, expectedName)
        }
    }

    func testCommitsTemporaryFileIntoReservedDestination() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let temporaryFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: temporaryFile)
        }
        let store = try DownloadFileStore(rootURL: root)
        let destination = try store.destinationURL(suggestedName: "song.mp3")
        let audioData = Data("audio".utf8)
        try audioData.write(to: temporaryFile)

        try store.commit(temporaryFileURL: temporaryFile, toReservedURL: destination)

        XCTAssertEqual(try Data(contentsOf: destination), audioData)
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryFile.path))
    }

    func testDiscardsReservedDestinationAfterDownloadFailure() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DownloadFileStore(rootURL: root)
        let destination = try store.destinationURL(suggestedName: "song.mp3")

        try store.discardReservation(at: destination)

        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }
}
