import Foundation
import XCTest
@testable import SimpleMusic

final class DownloadFileStoreTests: XCTestCase {
    /// 若播放层无法通过存储边界解析已下载文件，就只能绕过根目录约束自行拼路径。
    func testResolvesExistingRegularFileInsideStoreRoot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DownloadFileStore(rootURL: root)
        let fileURL = root.appendingPathComponent("song.mp3")
        try Data("audio".utf8).write(to: fileURL)

        let lease = try store.playbackLease(for: "song.mp3")

        XCTAssertNotEqual(lease.fileURL, fileURL.standardizedFileURL)
        XCTAssertEqual(try Data(contentsOf: lease.fileURL), Data("audio".utf8))
    }

    /// 若不存在的索引文件仍可解析，AVPlayer 会在远离存储边界处才失败。
    func testFileURLRejectsMissingFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DownloadFileStore(rootURL: root)

        XCTAssertThrowsError(try store.playbackLease(for: "missing.mp3"))
    }

    /// 若文件名可含分隔符或标准化越界，播放索引就能读取下载根目录外的文件。
    func testFileURLRejectsEmptySeparatorsAndTraversal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DownloadFileStore(rootURL: root)

        for fileName in ["", " ", "../outside.mp3", "folder/song.mp3", "folder\\song.mp3", ".", ".."] {
            XCTAssertThrowsError(try store.playbackLease(for: fileName), fileName)
        }
    }

    /// 若符号链接被视为普通下载文件，可借其读取根目录外的目标。
    func testFileURLRejectsSymbolicLink() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        try Data("outside".utf8).write(to: outside)
        let store = try DownloadFileStore(rootURL: root)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("linked.mp3"),
            withDestinationURL: outside
        )

        XCTAssertThrowsError(try store.playbackLease(for: "linked.mp3"))
    }

    /// 若目录被当作可播放文件返回，后端会获得无效的 AVPlayerItem。
    func testFileURLRejectsDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DownloadFileStore(rootURL: root)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("folder"), withIntermediateDirectories: false)

        XCTAssertThrowsError(try store.playbackLease(for: "folder"))
    }

    /// 若 lease 仍指向可替换的源路径，解析后替换为越界 symlink 会读到外部内容。
    func testPlaybackLeaseKeepsOriginalBytesAfterSourceIsReplacedBySymbolicLink() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let store = try DownloadFileStore(rootURL: root)
        let source = root.appendingPathComponent("song.mp3")
        try Data("trusted".utf8).write(to: source)
        try Data("outside".utf8).write(to: outside)

        let lease = try store.playbackLease(for: "song.mp3")
        try FileManager.default.removeItem(at: source)
        try FileManager.default.createSymbolicLink(at: source, withDestinationURL: outside)

        XCTAssertEqual(try Data(contentsOf: lease.fileURL), Data("trusted".utf8))
    }

    /// 若显式释放不清理 staging 文件，连续切歌会永久累积副本。
    func testPlaybackLeaseReleaseRemovesStagingFileIdempotently() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DownloadFileStore(rootURL: root)
        try Data("audio".utf8).write(to: root.appendingPathComponent("song.mp3"))
        let lease = try store.playbackLease(for: "song.mp3")
        let stagingURL = lease.fileURL

        lease.release()
        lease.release()

        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingURL.path))
    }

    /// 若 lease 析构不清理 staging 文件，异常退出当前播放也会泄漏副本。
    func testPlaybackLeaseDeinitRemovesStagingFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DownloadFileStore(rootURL: root)
        try Data("audio".utf8).write(to: root.appendingPathComponent("song.mp3"))
        var lease: PlaybackFileLease? = try store.playbackLease(for: "song.mp3")
        let stagingURL = try XCTUnwrap(lease?.fileURL)

        lease = nil

        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingURL.path))
    }

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
