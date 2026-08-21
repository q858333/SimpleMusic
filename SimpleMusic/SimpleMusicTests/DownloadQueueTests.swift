import Darwin
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

    func testRemovingActiveReservedJobWaitsForAttemptBeforeReleasingSlot() throws {
        let operation = ControlledQueueDownloadOperation(automaticallyCompletesCancellation: false)
        let recovery = GatedRecovery()
        let queue = makeQueue(
            operation: operation,
            recovery: recovery.perform,
            maximumActiveCount: 1
        )
        let activeURL = URL(string: "https://example.com/active.m4a")!
        let queuedURL = URL(string: "https://example.com/queued.m4a")!
        let activeID = try queue.enqueue(activeURL)
        _ = try queue.enqueue(queuedURL)
        waitUntil { operation.startedURLs == [activeURL] }
        try operation.reserve(url: activeURL, fileName: "active-reserved.m4a")

        queue.remove(id: activeID)
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))

        XCTAssertEqual(operation.cancellationCount, 1)
        XCTAssertEqual(recovery.invocationCount, 0)
        XCTAssertEqual(operation.startedURLs, [activeURL])
        XCTAssertNotNil(queue.jobs.first { $0.id == activeID })

        operation.completeCancellation(url: activeURL)
        waitUntil {
            queue.jobs.first { $0.id == activeID } == nil
                && operation.attemptCount(url: queuedURL) == 1
        }

        XCTAssertNil(queue.jobs.first { $0.id == activeID })
        XCTAssertEqual(operation.startedURLs, [activeURL, queuedURL])
        XCTAssertEqual(operation.attemptCount(url: queuedURL), 1)
        XCTAssertEqual(recovery.invocationCount, 0)

        recovery.releaseAll(with: .success(.cleaned))
        if operation.attemptCount(url: queuedURL) == 0 {
            waitUntil { operation.attemptCount(url: queuedURL) == 1 }
        }
        operation.succeed(url: queuedURL, track: track(id: "queued"))
        waitUntil { queue.jobs.allSatisfy { $0.state == .success } }
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

    func testRecoveryKeepsIndexedFileAndCleansOnlyUnindexedControlledFile() async throws {
        let base = try makeTemporaryDirectory()
        let downloadRoot = base.appendingPathComponent("Downloads", isDirectory: true)
        let fileStore = try DownloadFileStore(rootURL: downloadRoot)
        let musicStore = try LocalMusicStore.inMemory()
        let indexed = try musicStore.insert(DownloadedTrackMetadata(
            id: "indexed",
            fileName: "indexed.m4a",
            title: "Indexed",
            artist: "Artist",
            album: "Album",
            duration: 1
        ))
        let indexedFileURL = downloadRoot.appendingPathComponent("indexed.m4a")
        let orphanFileURL = downloadRoot.appendingPathComponent("orphan.m4a")
        try Data("indexed".utf8).write(to: indexedFileURL)
        try Data("orphan".utf8).write(to: orphanFileURL)
        let service = DownloadRecoveryService(fileStore: fileStore, musicStore: musicStore)

        let indexedDisposition = try await service.reconcile(fileName: "indexed.m4a")
        let orphanDisposition = try await service.reconcile(fileName: "orphan.m4a")
        XCTAssertEqual(indexedDisposition, .indexed)
        XCTAssertEqual(orphanDisposition, .cleaned)
        XCTAssertTrue(FileManager.default.fileExists(atPath: indexedFileURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanFileURL.path))
        XCTAssertEqual(indexed.id, try XCTUnwrap(try musicStore.fetchTracks().first).id)
    }

    func testRecoveryRejectsTraversalAndDoesNotDeleteExternalFile() async throws {
        let base = try makeTemporaryDirectory()
        let downloadRoot = base.appendingPathComponent("Downloads", isDirectory: true)
        let outside = base.appendingPathComponent("outside.m4a")
        try Data("outside".utf8).write(to: outside)
        let service = DownloadRecoveryService(
            fileStore: try DownloadFileStore(rootURL: downloadRoot),
            musicStore: try LocalMusicStore.inMemory()
        )

        do {
            _ = try await service.reconcile(fileName: "../outside.m4a")
            XCTFail("目录穿越必须被拒绝")
        } catch DownloadFileStoreError.invalidFileName {
            // 预期错误。
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    }

    func testTemporaryCleanupRemovesOnlyOwnedTransferFiles() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        let downloadRoot = temporaryDirectory.appendingPathComponent("Downloads", isDirectory: true)
        let owned = temporaryDirectory.appendingPathComponent("SimpleMusicDownload-owned")
        let unrelated = temporaryDirectory.appendingPathComponent("other-app.tmp")
        let similarlyNamedDirectory = temporaryDirectory.appendingPathComponent(
            "SimpleMusicDownload-directory",
            isDirectory: true
        )
        try Data("partial".utf8).write(to: owned)
        try Data("keep".utf8).write(to: unrelated)
        try FileManager.default.createDirectory(at: similarlyNamedDirectory, withIntermediateDirectories: true)
        let service = DownloadRecoveryService(
            fileStore: try DownloadFileStore(rootURL: downloadRoot),
            musicStore: try LocalMusicStore.inMemory(),
            temporaryDirectory: temporaryDirectory
        )

        try service.cleanupRetainedTemporaryFiles()

        XCTAssertFalse(FileManager.default.fileExists(atPath: owned.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: similarlyNamedDirectory.path))
    }

    func testTemporaryCleanupUnlinksOwnedSymlinkWithoutDeletingExternalTarget() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        let downloadRoot = temporaryDirectory.appendingPathComponent("Downloads", isDirectory: true)
        let outside = temporaryDirectory.appendingPathComponent("outside.m4a")
        let link = temporaryDirectory.appendingPathComponent("SimpleMusicDownload-link")
        try Data("outside".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let service = DownloadRecoveryService(
            fileStore: try DownloadFileStore(rootURL: downloadRoot),
            musicStore: try LocalMusicStore.inMemory(),
            temporaryDirectory: temporaryDirectory
        )

        try service.cleanupRetainedTemporaryFiles()

        var linkStatus = stat()
        XCTAssertEqual(Darwin.lstat(link.path, &linkStatus), -1)
        XCTAssertEqual(try Data(contentsOf: outside), Data("outside".utf8))
    }

    func testTemporaryCleanupRejectsDirectoryThatReplacesClassifiedFile() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        let downloadRoot = temporaryDirectory.appendingPathComponent("Downloads", isDirectory: true)
        let owned = temporaryDirectory.appendingPathComponent("SimpleMusicDownload-raced")
        let child = owned.appendingPathComponent("keep.txt")
        try Data("partial".utf8).write(to: owned)
        let service = DownloadRecoveryService(
            fileStore: try DownloadFileStore(rootURL: downloadRoot),
            musicStore: try LocalMusicStore.inMemory(),
            temporaryDirectory: temporaryDirectory,
            temporaryEntryStatusReader: { path, status in
                let result = Darwin.lstat(path, status)
                let errorCode = result < 0 ? errno : 0
                guard result == 0 else { return (result, errorCode) }
                try! FileManager.default.removeItem(atPath: path)
                try! FileManager.default.createDirectory(
                    atPath: path,
                    withIntermediateDirectories: false
                )
                try! Data("keep".utf8).write(to: child)
                return (result, errorCode)
            }
        )

        XCTAssertThrowsError(try service.cleanupRetainedTemporaryFiles())
        XCTAssertTrue(FileManager.default.fileExists(atPath: owned.path))
        XCTAssertEqual(try Data(contentsOf: child), Data("keep".utf8))
    }

    func testLaunchMarksUnfinishedInterruptedWithoutStartingNetwork() throws {
        let queuedJob = persistedJob(state: .queued)
        let downloadingJob = persistedJob(
            state: .downloading,
            progress: 0.65,
            reservedFileName: "downloading.m4a"
        )
        let failedJob = persistedJob(state: .failure, failureReason: .generic)
        let store = SpyQueueStore(initialJobs: [queuedJob, downloadingJob, failedJob])
        let operation = ControlledQueueDownloadOperation()
        let queue = makeQueue(operation: operation, store: store)

        XCTAssertEqual(job(queuedJob.id, in: queue).state, .interrupted)
        XCTAssertEqual(job(downloadingJob.id, in: queue).state, .interrupted)
        XCTAssertEqual(job(downloadingJob.id, in: queue).progress, 0)
        XCTAssertEqual(job(failedJob.id, in: queue).state, .failure)
        XCTAssertEqual(operation.startedURLs, [])
    }

    func testRecoveryRemovesIndexedRecordButKeepsInterruptedCleanedJob() {
        let indexedJob = persistedJob(
            state: .downloading,
            reservedFileName: "indexed.m4a"
        )
        let orphanJob = persistedJob(
            state: .downloading,
            reservedFileName: "orphan.m4a"
        )
        let store = SpyQueueStore(initialJobs: [indexedJob, orphanJob])
        let recovery = ControlledRecovery()
        recovery.results["indexed.m4a"] = .success(.indexed)
        recovery.results["orphan.m4a"] = .success(.cleaned)
        let queue = makeQueue(
            operation: ControlledQueueDownloadOperation(),
            store: store,
            recovery: recovery.perform
        )

        waitUntil { recovery.fileNames.count == 2 }
        XCTAssertNil(queue.jobs.first { $0.reservedFileName == "indexed.m4a" })
        XCTAssertEqual(job(orphanJob.id, in: queue).state, .interrupted)
        XCTAssertNil(job(orphanJob.id, in: queue).reservedFileName)
    }

    func testRecoveryErrorKeepsInterruptedRecordAndRetryReconcilesBeforeNetwork() {
        let interruptedJob = persistedJob(
            state: .downloading,
            progress: 0.4,
            reservedFileName: "retry.m4a"
        )
        let store = SpyQueueStore(initialJobs: [interruptedJob])
        let recovery = ControlledRecovery()
        recovery.results["retry.m4a"] = .failure(QueueRecoveryTestError.ioFailure)
        let operation = ControlledQueueDownloadOperation()
        let queue = makeQueue(
            operation: operation,
            store: store,
            recovery: recovery.perform
        )

        waitUntil { recovery.fileNames.count == 1 }
        XCTAssertEqual(job(interruptedJob.id, in: queue).state, .interrupted)
        XCTAssertEqual(job(interruptedJob.id, in: queue).failureReason, .recovery)
        XCTAssertEqual(job(interruptedJob.id, in: queue).reservedFileName, "retry.m4a")
        XCTAssertEqual(operation.startedURLs, [])

        recovery.results["retry.m4a"] = .success(.cleaned)
        queue.retry(id: interruptedJob.id)
        XCTAssertEqual(operation.startedURLs, [])
        waitUntil { recovery.fileNames.count == 2 }
        waitUntil { operation.startedURLs == [interruptedJob.sourceURL] }
        XCTAssertNil(job(interruptedJob.id, in: queue).reservedFileName)

        guard operation.startedURLs == [interruptedJob.sourceURL] else {
            return XCTFail("恢复清理成功后应启动一次新下载")
        }
        operation.succeed(url: interruptedJob.sourceURL, track: track(id: "retried"))
        waitUntil { job(interruptedJob.id, in: queue).state == .success }
    }

    func testRetryWaitsForOwnedLaunchRecoveryBeforeStartingNetwork() {
        let interruptedJob = persistedJob(
            state: .downloading,
            reservedFileName: "owned-retry.m4a"
        )
        let recovery = GatedRecovery()
        let operation = ControlledQueueDownloadOperation()
        let queue = makeQueue(
            operation: operation,
            store: SpyQueueStore(initialJobs: [interruptedJob]),
            recovery: recovery.perform
        )
        waitUntil { recovery.invocationCount == 1 }

        queue.retry(id: interruptedJob.id)
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))

        XCTAssertEqual(recovery.invocationCount, 1)
        XCTAssertEqual(operation.startedURLs, [])

        recovery.complete(at: 0, with: .success(.cleaned))
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        XCTAssertEqual(operation.startedURLs, [interruptedJob.sourceURL])

        if operation.startedURLs.isEmpty {
            recovery.releaseAll(with: .success(.cleaned))
            waitUntil { operation.startedURLs == [interruptedJob.sourceURL] }
        }
        guard operation.startedURLs == [interruptedJob.sourceURL] else {
            recovery.releaseAll(with: .success(.cleaned))
            return XCTFail("旧恢复收束后应只启动一次 retry")
        }
        operation.succeed(url: interruptedJob.sourceURL, track: track(id: "owned-retry"))
        waitUntil { job(interruptedJob.id, in: queue).state == .success }
        recovery.releaseAll(with: .success(.cleaned))
    }

    func testRemoveWaitsForOwnedRecoveryToFinish() {
        let interruptedJob = persistedJob(
            state: .downloading,
            reservedFileName: "owned-remove.m4a"
        )
        let recovery = GatedRecovery()
        let queue = makeQueue(
            operation: ControlledQueueDownloadOperation(),
            store: SpyQueueStore(initialJobs: [interruptedJob]),
            recovery: recovery.perform
        )
        waitUntil { recovery.invocationCount == 1 }

        queue.remove(id: interruptedJob.id)

        XCTAssertNotNil(queue.jobs.first { $0.id == interruptedJob.id })
        XCTAssertEqual(recovery.invocationCount, 1)
        recovery.complete(at: 0, with: .success(.cleaned))
        waitUntil { queue.jobs.first { $0.id == interruptedJob.id } == nil }
        recovery.releaseAll(with: .success(.cleaned))
    }

    func testPendingRetryPrecedesLaterEnqueueAndOwnsOnlyAutoPlayEligibility() throws {
        let retryJob = persistedJob(
            state: .downloading,
            reservedFileName: "retry-first.m4a"
        )
        let recovery = GatedRecovery()
        let operation = ControlledQueueDownloadOperation()
        var playedIDs = [String]()
        let queue = makeQueue(
            operation: operation,
            store: SpyQueueStore(initialJobs: [retryJob]),
            settings: makeSettings(autoPlay: true),
            recovery: recovery.perform,
            onPlay: { playedIDs.append($0.id) },
            maximumActiveCount: 1
        )
        waitUntil { recovery.invocationCount == 1 }
        let enqueuedURL = URL(string: "https://example.com/enqueued-second.m4a")!

        queue.retry(id: retryJob.id)
        _ = try queue.enqueue(enqueuedURL)
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))

        XCTAssertEqual(operation.startedURLs, [])
        recovery.releaseAll(with: .success(.cleaned))
        waitUntil { !operation.startedURLs.isEmpty }
        XCTAssertEqual(operation.startedURLs.first, retryJob.sourceURL)

        guard let firstURL = operation.startedURLs.first else {
            return XCTFail("恢复后应启动 retry")
        }
        operation.succeed(url: firstURL, track: track(id: firstURL.lastPathComponent))
        waitUntil { operation.startedURLs.count == 2 }
        let secondURL = operation.startedURLs[1]
        operation.succeed(url: secondURL, track: track(id: secondURL.lastPathComponent))
        waitUntil { queue.jobs.allSatisfy { $0.state == .success } }

        XCTAssertEqual(operation.startedURLs, [retryJob.sourceURL, enqueuedURL])
        XCTAssertEqual(playedIDs, [retryJob.sourceURL.lastPathComponent])
    }

    func testTwoPendingRetriesKeepUserActionOrderAndSingleAutoPlayEligibility() {
        let firstJob = persistedJob(
            state: .downloading,
            reservedFileName: "first-retry.m4a"
        )
        let secondJob = persistedJob(
            state: .downloading,
            reservedFileName: "second-retry.m4a"
        )
        let recovery = GatedRecovery()
        let operation = ControlledQueueDownloadOperation()
        var playedIDs = [String]()
        let queue = makeQueue(
            operation: operation,
            store: SpyQueueStore(initialJobs: [firstJob, secondJob]),
            settings: makeSettings(autoPlay: true),
            recovery: recovery.perform,
            onPlay: { playedIDs.append($0.id) },
            maximumActiveCount: 1
        )
        waitUntil { recovery.invocationCount == 1 }

        queue.retry(id: firstJob.id)
        queue.retry(id: secondJob.id)
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))

        XCTAssertEqual(operation.startedURLs, [])
        XCTAssertEqual(recovery.invocationCount, 1)
        recovery.releaseAll(with: .success(.cleaned))
        waitUntil { !operation.startedURLs.isEmpty }
        XCTAssertEqual(operation.startedURLs.first, firstJob.sourceURL)

        guard let firstURL = operation.startedURLs.first else {
            return XCTFail("恢复完成后应启动第一个 retry")
        }
        operation.succeed(url: firstURL, track: track(id: firstURL.lastPathComponent))
        waitUntil { operation.startedURLs.count == 2 }
        let secondURL = operation.startedURLs[1]
        operation.succeed(url: secondURL, track: track(id: secondURL.lastPathComponent))
        waitUntil { queue.jobs.allSatisfy { $0.state == .success } }

        XCTAssertEqual(operation.startedURLs, [firstJob.sourceURL, secondJob.sourceURL])
        XCTAssertEqual(playedIDs, [firstJob.sourceURL.lastPathComponent])
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

    private func persistedJob(
        state: DownloadJob.State,
        progress: Double = 0,
        failureReason: DownloadJob.FailureReason? = nil,
        reservedFileName: String? = nil
    ) -> DownloadJob {
        DownloadJob(
            id: UUID(),
            sourceURL: URL(string: "https://example.com/\(UUID().uuidString).m4a")!,
            displayName: "persisted.m4a",
            state: state,
            progress: progress,
            createdAt: Date(timeIntervalSince1970: 1),
            attempt: 1,
            failureReason: failureReason,
            reservedFileName: reservedFileName
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
        store: (any DownloadQueuePersisting)? = nil,
        settings: SettingsStore? = nil,
        recovery: @escaping DownloadQueue.RecoveryOperation = { _ in .cleaned },
        onPlay: @escaping @MainActor (MusicTrack) -> Void = { _ in },
        maximumActiveCount: Int = 3,
        now: @escaping @MainActor () -> Date = Date.init
    ) -> DownloadQueue {
        DownloadQueue(
            store: store ?? RecordingQueueStore(),
            operation: operation.perform,
            settingsStore: settings ?? makeSettings(autoPlay: false),
            recovery: recovery,
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
private final class SpyQueueStore: DownloadQueuePersisting {
    var loadedJobs: [DownloadJob]
    private(set) var saves = [[DownloadJob]]()

    init(initialJobs: [DownloadJob]) {
        loadedJobs = initialJobs
    }

    func load() throws -> [DownloadJob] { loadedJobs }

    func save(_ jobs: [DownloadJob]) throws {
        loadedJobs = jobs
        saves.append(jobs)
    }
}

@MainActor
private final class ControlledRecovery {
    var results = [String: Result<DownloadQueue.RecoveryDisposition, Error>]()
    private(set) var fileNames = [String]()

    func perform(_ fileName: String) async throws -> DownloadQueue.RecoveryDisposition {
        fileNames.append(fileName)
        return try XCTUnwrap(results[fileName]).get()
    }
}

@MainActor
private final class GatedRecovery {
    private struct Invocation {
        let fileName: String
        var continuation: CheckedContinuation<DownloadQueue.RecoveryDisposition, Error>?
    }

    private var invocations = [Invocation]()
    private var releasedResult: Result<DownloadQueue.RecoveryDisposition, Error>?
    var invocationCount: Int { invocations.count }

    func perform(_ fileName: String) async throws -> DownloadQueue.RecoveryDisposition {
        if let releasedResult {
            return try releasedResult.get()
        }
        return try await withCheckedThrowingContinuation { continuation in
            invocations.append(Invocation(fileName: fileName, continuation: continuation))
        }
    }

    func complete(
        at index: Int,
        with result: Result<DownloadQueue.RecoveryDisposition, Error>
    ) {
        guard invocations.indices.contains(index),
              let continuation = invocations[index].continuation else { return }
        invocations[index].continuation = nil
        continuation.resume(with: result)
    }

    func releaseAll(with result: Result<DownloadQueue.RecoveryDisposition, Error>) {
        releasedResult = result
        let pending = invocations.compactMap(\.continuation)
        invocations.removeAll()
        pending.forEach { $0.resume(with: result) }
    }
}

private enum QueueRecoveryTestError: Error {
    case ioFailure
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
    private let automaticallyCompletesCancellation: Bool
    var startedURLs: [URL] { invocations.map(\.url) }

    init(automaticallyCompletesCancellation: Bool = true) {
        self.automaticallyCompletesCancellation = automaticallyCompletesCancellation
    }

    func perform(
        url: URL,
        progress: @escaping @MainActor @Sendable (Double) -> Void,
        reservation: @escaping @MainActor @Sendable (String) throws -> Void
    ) async throws -> MusicTrack {
        let index = invocations.count
        let automaticallyCompletesCancellation = automaticallyCompletesCancellation
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
                cancellationCount += 1
                if automaticallyCompletesCancellation {
                    invocations[index].continuation = nil
                    continuation.resume(throwing: CancellationError())
                }
            }
        }
    }

    func attemptCount(url: URL) -> Int { invocations.filter { $0.url == url }.count }

    func report(url: URL, attempt: Int, progress: Double) {
        invocation(url: url, attempt: attempt).progress(progress)
    }

    func reserve(url: URL, attempt: Int = 0, fileName: String) throws {
        try invocation(url: url, attempt: attempt).reservation(fileName)
    }

    func completeCancellation(url: URL, attempt: Int = 0) {
        let invocation = invocation(url: url, attempt: attempt)
        let continuation = invocation.continuation
        invocation.continuation = nil
        continuation?.resume(throwing: CancellationError())
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
