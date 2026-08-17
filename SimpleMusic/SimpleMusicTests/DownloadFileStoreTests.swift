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
            let destination = try! store.reserveDestination(suggestedName: "song.mp3").destinationURL
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

        let destination = try store.reserveDestination(suggestedName: "../../song.mp3").destinationURL

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

            XCTAssertEqual(try store.reserveDestination(suggestedName: suggestedName).destinationURL.lastPathComponent, expectedName)
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
        let reservation = try store.reserveDestination(suggestedName: "song.mp3")
        let audioData = Data("audio".utf8)
        try audioData.write(to: temporaryFile)

        try store.commit(temporaryFileURL: temporaryFile, reservation: reservation)

        XCTAssertEqual(try Data(contentsOf: reservation.destinationURL), audioData)
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryFile.path))
    }

    func testDiscardsReservedDestinationAfterDownloadFailure() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DownloadFileStore(rootURL: root)
        let reservation = try store.reserveDestination(suggestedName: "song.mp3")

        try store.discard(reservation: reservation)

        XCTAssertFalse(FileManager.default.fileExists(atPath: reservation.destinationURL.path))
    }

    func testCommitPreservesArbitraryExistingFileWithSameSuggestedName() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let temporaryFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: temporaryFile)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let existingFile = root.appendingPathComponent("song.mp3")
        let existingData = Data("existing".utf8)
        let downloadedData = Data("downloaded".utf8)
        try existingData.write(to: existingFile)
        try downloadedData.write(to: temporaryFile)
        let store = try DownloadFileStore(rootURL: root)

        let reservation = try store.reserveDestination(suggestedName: "song.mp3")
        try store.commit(temporaryFileURL: temporaryFile, reservation: reservation)

        XCTAssertNotEqual(reservation.destinationURL, existingFile)
        XCTAssertEqual(try Data(contentsOf: existingFile), existingData)
        XCTAssertEqual(try Data(contentsOf: reservation.destinationURL), downloadedData)
    }

    func testRejectsReservationCreatedByAnotherStoreAtSameRoot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = try DownloadFileStore(rootURL: root)
        let otherStore = try DownloadFileStore(rootURL: root)
        let reservation = try owner.reserveDestination(suggestedName: "song.mp3")

        XCTAssertThrowsError(try otherStore.discard(reservation: reservation))
        XCTAssertTrue(FileManager.default.fileExists(atPath: reservation.destinationURL.path))

        try owner.discard(reservation: reservation)
    }

    func testCommitConsumesReservation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let firstTemporaryFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let secondTemporaryFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: firstTemporaryFile)
            try? FileManager.default.removeItem(at: secondTemporaryFile)
        }
        let store = try DownloadFileStore(rootURL: root)
        let reservation = try store.reserveDestination(suggestedName: "song.mp3")
        let firstData = Data("first".utf8)
        try firstData.write(to: firstTemporaryFile)
        try Data("second".utf8).write(to: secondTemporaryFile)

        try store.commit(temporaryFileURL: firstTemporaryFile, reservation: reservation)

        XCTAssertThrowsError(try store.commit(temporaryFileURL: secondTemporaryFile, reservation: reservation))
        XCTAssertEqual(try Data(contentsOf: reservation.destinationURL), firstData)
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondTemporaryFile.path))
    }

    func testDiscardAfterCommitDoesNotDeleteFinalContent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let temporaryFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: temporaryFile)
        }
        let store = try DownloadFileStore(rootURL: root)
        let reservation = try store.reserveDestination(suggestedName: "song.mp3")
        let audioData = Data("audio".utf8)
        try audioData.write(to: temporaryFile)
        try store.commit(temporaryFileURL: temporaryFile, reservation: reservation)

        XCTAssertThrowsError(try store.discard(reservation: reservation))
        XCTAssertEqual(try Data(contentsOf: reservation.destinationURL), audioData)
    }

    func testCommitAfterDiscardFailsAndLeavesTemporaryFileUntouched() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let temporaryFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: temporaryFile)
        }
        let store = try DownloadFileStore(rootURL: root)
        let reservation = try store.reserveDestination(suggestedName: "song.mp3")
        try Data("audio".utf8).write(to: temporaryFile)
        try store.discard(reservation: reservation)

        XCTAssertThrowsError(try store.commit(temporaryFileURL: temporaryFile, reservation: reservation))
        XCTAssertFalse(FileManager.default.fileExists(atPath: reservation.destinationURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: temporaryFile.path))
    }
}
