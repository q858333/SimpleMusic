import XCTest
@testable import SimpleMusic

@MainActor
final class DownloadQueueTests: XCTestCase {
    func testQueueStoreRoundTripsRecoverableJobFields() throws {
        let fileURL = try makeTemporaryDirectory()
            .appendingPathComponent("download-queue.json")
        let store = DownloadQueueStore(fileURL: fileURL)
        let job = DownloadJob(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            sourceURL: URL(string: "https://example.com/a.m4a")!,
            displayName: "a.m4a",
            state: .downloading,
            progress: 0.45,
            createdAt: Date(timeIntervalSince1970: 42),
            attempt: 3,
            failureReason: nil,
            reservedFileName: "a-1234.m4a"
        )

        try store.save([job])

        XCTAssertEqual(try DownloadQueueStore(fileURL: fileURL).load(), [job])
    }

    func testCorruptQueueLedgerThrowsWithoutReplacingOriginalBytes() throws {
        let fileURL = try makeTemporaryDirectory()
            .appendingPathComponent("download-queue.json")
        let original = Data("{not-json".utf8)
        try original.write(to: fileURL)

        XCTAssertThrowsError(try DownloadQueueStore(fileURL: fileURL).load())
        XCTAssertEqual(try Data(contentsOf: fileURL), original)
    }

    func testMemoryQueueStoreDoesNotWriteAFile() throws {
        let initial = [makeJob(state: .interrupted)]
        let store = DownloadQueueStore(fileURL: nil, initialJobs: initial)

        XCTAssertEqual(try store.load(), initial)
        try store.save([])
        XCTAssertEqual(try store.load(), [])
    }

    private func makeJob(state: DownloadJob.State) -> DownloadJob {
        DownloadJob(
            id: UUID(),
            sourceURL: URL(string: "https://example.com/test.m4a")!,
            displayName: "test.m4a",
            state: state,
            progress: 0,
            createdAt: Date(timeIntervalSince1970: 1),
            attempt: 0,
            failureReason: nil,
            reservedFileName: nil
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DownloadQueueTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
