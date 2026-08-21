import XCTest
@testable import SimpleMusic

@MainActor
final class DownloadQueueTests: XCTestCase {
    func testQueueStartsThreeAndWaitsFourthUntilFirstFinishes() throws {
        let operation = ControlledQueueDownloadOperation()
        let queue = makeQueue(operation: operation)
        let urls = (1...4).map { URL(string: "https://example.com/\($0).m4a")! }

        let ids = try urls.map { try queue.enqueue($0) }
        waitUntil { operation.startedURLs.count == 3 }

        XCTAssertEqual(operation.startedURLs, Array(urls.prefix(3)))
        XCTAssertEqual(queue.jobs.first?.id, ids.last)
        XCTAssertEqual(job(ids[3], in: queue).state, .queued)

        operation.succeed(url: urls[0], track: track(id: "one"))
        waitUntil { operation.startedURLs == urls }
        XCTAssertEqual(job(ids[3], in: queue).state, .downloading)

        operation.succeed(url: urls[1], track: track(id: "two"))
        operation.succeed(url: urls[2], track: track(id: "three"))
        operation.succeed(url: urls[3], track: track(id: "four"))
        waitUntil { queue.jobs.allSatisfy { $0.state == .success } }
    }

    func testFailureAndCancellationEachReleaseExactlyOneSlot() throws {
        let operation = ControlledQueueDownloadOperation()
        let queue = makeQueue(operation: operation)
        let urls = (1...5).map { URL(string: "https://example.com/\($0).m4a")! }
        let ids = try urls.map { try queue.enqueue($0) }
        waitUntil { operation.startedURLs.count == 3 }

        operation.fail(url: urls[0], error: DownloadError.unsupportedResponse)
        waitUntil { operation.startedURLs.count == 4 }
        XCTAssertEqual(operation.startedURLs.last, urls[3])
        XCTAssertEqual(queue.jobs.filter { $0.state == .downloading }.count, 3)

        queue.cancel(id: ids[1])
        waitUntil { operation.startedURLs.count == 5 }
        XCTAssertEqual(operation.startedURLs.last, urls[4])
        XCTAssertEqual(queue.jobs.filter { $0.state == .downloading }.count, 3)
        XCTAssertEqual(operation.cancellationCount, 1)

        operation.succeed(url: urls[2], track: track(id: "three"))
        operation.succeed(url: urls[3], track: track(id: "four"))
        operation.succeed(url: urls[4], track: track(id: "five"))
        waitUntil { queue.jobs.filter { $0.state == .downloading }.isEmpty }
    }

    func testCancelAndRetryIgnoreOldAttemptCallbacks() throws {
        let operation = ControlledQueueDownloadOperation()
        let queue = makeQueue(operation: operation)
        let url = URL(string: "https://example.com/a.m4a")!
        let id = try queue.enqueue(url)
        waitUntil { operation.attemptCount(url: url) == 1 }

        operation.report(url: url, attempt: 0, progress: 0.4)
        XCTAssertEqual(job(id, in: queue).progress, 0.4)
        queue.cancel(id: id)
        waitUntil { job(id, in: queue).state == .cancelled }

        queue.retry(id: id)
        waitUntil { operation.attemptCount(url: url) == 2 }
        XCTAssertEqual(job(id, in: queue).progress, 0)

        operation.report(url: url, attempt: 0, progress: 0.9)
        operation.succeed(url: url, attempt: 0, track: track(id: "old"))
        XCTAssertEqual(job(id, in: queue).state, .downloading)
        XCTAssertEqual(job(id, in: queue).progress, 0)

        operation.succeed(url: url, attempt: 1, track: track(id: "new"))
        waitUntil { job(id, in: queue).state == .success }
    }

    func testProgressForOneJobDoesNotChangeOtherJobs() throws {
        let operation = ControlledQueueDownloadOperation()
        let queue = makeQueue(operation: operation)
        let firstURL = URL(string: "https://example.com/one.m4a")!
        let secondURL = URL(string: "https://example.com/two.m4a")!
        let first = try queue.enqueue(firstURL)
        let second = try queue.enqueue(secondURL)
        waitUntil { operation.startedURLs.count == 2 }

        operation.report(url: firstURL, attempt: 0, progress: 0.42)
        XCTAssertEqual(job(first, in: queue).progress, 0.42)
        XCTAssertEqual(job(second, in: queue).progress, 0)

        operation.succeed(url: firstURL, track: track(id: "one"))
        operation.succeed(url: secondURL, track: track(id: "two"))
        waitUntil { queue.jobs.allSatisfy { $0.state == .success } }
    }

    func testRemovingActiveJobCancelsThenRemovesAfterTerminalCallback() throws {
        let operation = ControlledQueueDownloadOperation()
        let queue = makeQueue(operation: operation)
        let url = URL(string: "https://example.com/a.m4a")!
        let id = try queue.enqueue(url)
        waitUntil { operation.attemptCount(url: url) == 1 }

        queue.remove(id: id)
        XCTAssertEqual(job(id, in: queue).state, .cancelled)
        waitUntil { !queue.jobs.contains(where: { $0.id == id }) }
        XCTAssertEqual(operation.cancellationCount, 1)
    }

    func testRemovingActiveJobAfterSuccessSignalStillRemovesAfterTerminalCallback() throws {
        let operation = ControlledQueueDownloadOperation()
        let queue = makeQueue(operation: operation)
        let url = URL(string: "https://example.com/a.m4a")!
        let id = try queue.enqueue(url)
        waitUntil { operation.attemptCount(url: url) == 1 }

        operation.succeed(url: url, track: track(id: "one"))
        queue.remove(id: id)
        waitUntil { !queue.jobs.contains(where: { $0.id == id }) }
    }

    func testProgressPersistsOnlyAtFivePercentBucketsButPublishesEveryValue() throws {
        let operation = ControlledQueueDownloadOperation()
        let store = RecordingQueueStore()
        let queue = makeQueue(operation: operation, store: store)
        let url = URL(string: "https://example.com/a.m4a")!
        let id = try queue.enqueue(url)
        waitUntil { operation.attemptCount(url: url) == 1 }
        let savesBeforeProgress = store.savedJobs.count
        var publishedProgress = [Double]()
        let cancellable = queue.jobsPublisher.sink { jobs in
            if let job = jobs.first(where: { $0.id == id }) {
                publishedProgress.append(job.progress)
            }
        }
        defer { cancellable.cancel() }

        operation.report(url: url, attempt: 0, progress: 0.01)
        operation.report(url: url, attempt: 0, progress: 0.049)
        operation.report(url: url, attempt: 0, progress: 0.05)
        operation.report(url: url, attempt: 0, progress: 0.099)
        operation.report(url: url, attempt: 0, progress: 0.1)

        XCTAssertEqual(store.savedJobs.count, savesBeforeProgress + 2)
        XCTAssertEqual(publishedProgress.suffix(5), [0.01, 0.049, 0.05, 0.099, 0.1])

        operation.succeed(url: url, track: track(id: "one"))
        waitUntil { job(id, in: queue).state == .success }
    }

    func testUnsupportedURLBecomesEnqueueErrorWithoutCreatingJob() {
        let operation = ControlledQueueDownloadOperation()
        let queue = makeQueue(operation: operation)

        XCTAssertThrowsError(try queue.enqueue(URL(string: "ftp://example.com/a.m4a")!)) { error in
            XCTAssertTrue(error is DownloadError)
        }
        XCTAssertTrue(queue.jobs.isEmpty)
        XCTAssertTrue(operation.startedURLs.isEmpty)
    }

    func testOnlySingleEligibleAttemptAutoPlaysAndManualPlayConsumesOnce() throws {
        let operation = ControlledQueueDownloadOperation()
        var playedTracks = [MusicTrack]()
        let settings = makeSettings(autoPlay: true)
        let queue = makeQueue(
            operation: operation,
            settings: settings,
            onPlay: { playedTracks.append($0) }
        )
        let firstURL = URL(string: "https://example.com/one.m4a")!
        let secondURL = URL(string: "https://example.com/two.m4a")!
        let first = try queue.enqueue(firstURL)
        let second = try queue.enqueue(secondURL)
        waitUntil { operation.startedURLs.count == 2 }

        operation.succeed(url: firstURL, track: track(id: "one"))
        operation.succeed(url: secondURL, track: track(id: "two"))
        waitUntil { queue.jobs.filter { $0.state == .success }.count == 2 }

        XCTAssertEqual(playedTracks.map(\.id), ["one"])
        queue.play(id: second)
        queue.play(id: second)
        XCTAssertEqual(playedTracks.map(\.id), ["one", "two"])
        XCTAssertEqual(job(first, in: queue).state, .success)
    }

    func testRetryRecomputesAutoPlayEligibility() throws {
        let operation = ControlledQueueDownloadOperation()
        var playedTracks = [MusicTrack]()
        let queue = makeQueue(
            operation: operation,
            settings: makeSettings(autoPlay: true),
            onPlay: { playedTracks.append($0) }
        )
        let firstURL = URL(string: "https://example.com/one.m4a")!
        let secondURL = URL(string: "https://example.com/two.m4a")!
        let first = try queue.enqueue(firstURL)
        _ = try queue.enqueue(secondURL)
        waitUntil { operation.startedURLs.count == 2 }

        operation.fail(url: firstURL, error: DownloadError.unsupportedResponse)
        waitUntil { job(first, in: queue).state == .failure }
        queue.retry(id: first)
        waitUntil { operation.attemptCount(url: firstURL) == 2 }
        operation.succeed(url: firstURL, attempt: 1, track: track(id: "retry"))
        operation.succeed(url: secondURL, track: track(id: "second"))
        waitUntil { queue.jobs.filter { $0.state == .success }.count == 2 }

        XCTAssertTrue(playedTracks.isEmpty)
    }

    func testQueuedSecondDoesNotAutoPlayAfterSingleSlotBecomesFree() throws {
        let operation = ControlledQueueDownloadOperation()
        var playedTracks = [MusicTrack]()
        let queue = makeQueue(
            operation: operation,
            settings: makeSettings(autoPlay: true),
            onPlay: { playedTracks.append($0) },
            maximumActiveCount: 1
        )
        let firstURL = URL(string: "https://example.com/one.m4a")!
        let secondURL = URL(string: "https://example.com/two.m4a")!
        _ = try queue.enqueue(firstURL)
        _ = try queue.enqueue(secondURL)
        waitUntil { operation.startedURLs == [firstURL] }

        operation.succeed(url: firstURL, track: track(id: "one"))
        waitUntil { operation.startedURLs == [firstURL, secondURL] }
        operation.succeed(url: secondURL, track: track(id: "two"))
        waitUntil { queue.jobs.filter { $0.state == .success }.count == 2 }

        XCTAssertEqual(playedTracks.map(\.id), ["one"])
    }

    func testQueueStartsSameTimestampJobsInSubmissionOrderWithSingleSlot() throws {
        let operation = ControlledQueueDownloadOperation()
        let timestamp = Date(timeIntervalSince1970: 42)
        let queue = makeQueue(
            operation: operation,
            maximumActiveCount: 1,
            now: { timestamp }
        )
        let urls = (1...4).map { URL(string: "https://example.com/\($0).m4a")! }
        let ids = try urls.map { try queue.enqueue($0) }
        XCTAssertEqual(queue.jobs.map(\.id), ids.reversed())
        waitUntil { operation.startedURLs.count == 1 }

        for (index, url) in urls.enumerated() {
            XCTAssertEqual(operation.startedURLs[index], url)
            operation.succeed(url: url, track: track(id: "\(index)"))
            if index < urls.count - 1 {
                waitUntil { operation.startedURLs.count == index + 2 }
            }
        }
        waitUntil { queue.jobs.allSatisfy { $0.state == .success } }
    }

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

    private func makeQueue(
        operation: ControlledQueueDownloadOperation,
        store: RecordingQueueStore? = nil,
        settings: SettingsStore? = nil,
        onPlay: @escaping @MainActor (MusicTrack) -> Void = { _ in },
        maximumActiveCount: Int = 3,
        now: @escaping @MainActor () -> Date = Date.init
    ) -> DownloadQueue {
        DownloadQueue(
            store: store ?? RecordingQueueStore(),
            operation: operation.perform,
            settingsStore: settings ?? makeSettings(autoPlay: false),
            recovery: { _ in .cleaned },
            onReload: {},
            onPlay: onPlay,
            maximumActiveCount: maximumActiveCount,
            now: now
        )
    }

    private func makeSettings(autoPlay: Bool) -> SettingsStore {
        let name = "DownloadQueueTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let settings = SettingsStore(defaults: defaults)
        settings.autoPlayAfterDownload = autoPlay
        return settings
    }

    private func job(_ id: UUID, in queue: DownloadQueue) -> DownloadJob {
        guard let job = queue.jobs.first(where: { $0.id == id }) else {
            XCTFail("Missing job \(id)")
            fatalError()
        }
        return job
    }

    private func track(id: String) -> MusicTrack {
        MusicTrack(
            id: id,
            title: id,
            artist: "Artist",
            album: "Album",
            duration: 1,
            artworkData: nil,
            source: .downloaded(fileName: "\(id).m4a")
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 1,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () -> Bool
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(condition(), file: file, line: line)
    }
}

@MainActor
private final class RecordingQueueStore: DownloadQueuePersisting {
    private var jobs = [DownloadJob]()
    private(set) var savedJobs = [[DownloadJob]]()

    func load() throws -> [DownloadJob] { jobs }

    func save(_ jobs: [DownloadJob]) throws {
        self.jobs = jobs
        savedJobs.append(jobs)
    }
}

@MainActor
private final class ControlledQueueDownloadOperation {
    private final class Invocation {
        let url: URL
        let progress: @MainActor @Sendable (Double) -> Void
        let reservation: @MainActor @Sendable (String) throws -> Void
        var continuation: CheckedContinuation<MusicTrack, Error>?

        init(
            url: URL,
            progress: @escaping @MainActor @Sendable (Double) -> Void,
            reservation: @escaping @MainActor @Sendable (String) throws -> Void,
            continuation: CheckedContinuation<MusicTrack, Error>
        ) {
            self.url = url
            self.progress = progress
            self.reservation = reservation
            self.continuation = continuation
        }
    }

    private var invocations = [Invocation]()
    private(set) var cancellationCount = 0
    var startedURLs: [URL] { invocations.map(\.url) }

    func perform(
        url: URL,
        progress: @escaping @MainActor @Sendable (Double) -> Void,
        reservation: @escaping @MainActor @Sendable (String) throws -> Void
    ) async throws -> MusicTrack {
        let index = invocations.count
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                invocations.append(Invocation(
                    url: url,
                    progress: progress,
                    reservation: reservation,
                    continuation: continuation
                ))
            }
        } onCancel: { [weak self] in
            Task { @MainActor in
                guard let self, invocations.indices.contains(index),
                      let continuation = invocations[index].continuation else { return }
                invocations[index].continuation = nil
                cancellationCount += 1
                continuation.resume(throwing: CancellationError())
            }
        }
    }

    func attemptCount(url: URL) -> Int { invocations.filter { $0.url == url }.count }

    func report(url: URL, attempt: Int, progress: Double) {
        invocation(url: url, attempt: attempt).progress(progress)
    }

    func succeed(url: URL, attempt: Int = 0, track: MusicTrack) {
        let invocation = invocation(url: url, attempt: attempt)
        let continuation = invocation.continuation
        invocation.continuation = nil
        continuation?.resume(returning: track)
    }

    func fail(url: URL, attempt: Int = 0, error: Error) {
        let invocation = invocation(url: url, attempt: attempt)
        let continuation = invocation.continuation
        invocation.continuation = nil
        continuation?.resume(throwing: error)
    }

    private func invocation(url: URL, attempt: Int) -> Invocation {
        invocations.filter { $0.url == url }[attempt]
    }
}
