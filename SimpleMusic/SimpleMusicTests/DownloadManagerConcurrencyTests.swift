import Foundation
import XCTest
@testable import SimpleMusic

@MainActor
final class DownloadManagerConcurrencyTests: XCTestCase {
    func testTimeoutDoesNotReturnWhileAuxiliaryOperationIsStillRunning() async throws {
        let gate = ManualTaskGate()
        let task = ObservedTask<Void>(description: "受控任务结束") {
            await gate.wait()
        }

        do {
            _ = try await taskResults(
                [task],
                operation: "受控任务结束",
                timeout: 0.01,
                cleanup: { await gate.open() }
            )
            XCTFail("未完成 operation 必须触发超时")
        } catch let error as TestTimeoutError {
            XCTAssertEqual(error.operation, "受控任务结束")
            XCTAssertTrue(task.task.isCancelled)
        }
    }

    func testCancellationBeforeStartWaiterEnqueueResumesWithoutHanging() async throws {
        let gate = ManualTaskGate()
        let startedProbe = StartedCountProbe()
        let waitingTask = ObservedTask<Void>(description: "早取消 started waiter") {
            await gate.wait()
            try await startedProbe.wait(for: 1, timeout: 0.2)
        }
        waitingTask.task.cancel()
        await gate.open()

        let result = try await taskResults(
            [waitingTask],
            operation: "入队前取消 started waiter",
            timeout: 0.2,
            cleanup: { await gate.open() }
        )[0]
        guard case .failure(let error) = result else {
            return XCTFail("入队前取消的 waiter 不应成功")
        }
        XCTAssertTrue(error is CancellationError)
    }

    func testFourthDownloadStartsOnlyAfterOneOfThreeActiveDownloadsFinishes() async throws {
        let harness = try makeHarness()
        let firstURLs = (0..<3).map { audioURL(index: $0) }
        let firstTasks = firstURLs.map { harness.downloadTask(from: $0) }
        try await harness.client.waitUntilStarted(count: 3)

        let fourthURL = audioURL(index: 3)
        let fourthTask = harness.downloadTask(from: fourthURL)
        let queuedFourthURL = try await harness.queueEvents.next()
        XCTAssertEqual(queuedFourthURL, fourthURL)

        var snapshot = await harness.client.snapshot()
        XCTAssertEqual(snapshot.startedURLs.count, 3)
        XCTAssertEqual(snapshot.maximumActiveCount, 3)

        await harness.client.failDownload(for: firstURLs[0])
        try await harness.client.waitUntilStarted(count: 4)

        snapshot = await harness.client.snapshot()
        XCTAssertEqual(snapshot.startedURLs.last, fourthURL)
        XCTAssertEqual(snapshot.maximumActiveCount, 3)

        await harness.client.failAllDownloads()
        _ = try await taskResults(
            firstTasks + [fourthTask],
            operation: "并发上限测试收尾",
            cleanup: { await harness.client.shutdown() }
        )
    }

    func testQueuedDownloadsStartInSubmissionOrder() async throws {
        let harness = try makeHarness()
        let firstURLs = (0..<3).map { audioURL(index: $0) }
        let firstTasks = firstURLs.map { harness.downloadTask(from: $0) }
        try await harness.client.waitUntilStarted(count: 3)

        let fourthURL = audioURL(index: 3)
        let fourthTask = harness.downloadTask(from: fourthURL)
        let queuedFourthURL = try await harness.queueEvents.next()
        XCTAssertEqual(queuedFourthURL, fourthURL)
        let fifthURL = audioURL(index: 4)
        let fifthTask = harness.downloadTask(from: fifthURL)
        let queuedFifthURL = try await harness.queueEvents.next()
        XCTAssertEqual(queuedFifthURL, fifthURL)

        await harness.client.failDownload(for: firstURLs[0])
        try await harness.client.waitUntilStarted(count: 4)
        var snapshot = await harness.client.snapshot()
        XCTAssertEqual(snapshot.startedURLs.last, fourthURL)

        await harness.client.failDownload(for: fourthURL)
        try await harness.client.waitUntilStarted(count: 5)
        snapshot = await harness.client.snapshot()
        XCTAssertEqual(snapshot.startedURLs.last, fifthURL)

        await harness.client.failAllDownloads()
        _ = try await taskResults(
            firstTasks + [fourthTask, fifthTask],
            operation: "FIFO 测试收尾",
            cleanup: { await harness.client.shutdown() }
        )
    }

    func testCancellingQueuedFourthDownloadDoesNotConsumePermitOrBlockFifth() async throws {
        let harness = try makeHarness()
        let firstURLs = (0..<3).map { audioURL(index: $0) }
        let firstTasks = firstURLs.map { harness.downloadTask(from: $0) }
        try await harness.client.waitUntilStarted(count: 3)

        let cancelledURL = audioURL(index: 3)
        let cancelledTask = harness.downloadTask(from: cancelledURL)
        let queuedCancelledURL = try await harness.queueEvents.next()
        XCTAssertEqual(queuedCancelledURL, cancelledURL)
        cancelledTask.task.cancel()
        let cancelledResult = try await taskResults(
            [cancelledTask],
            operation: "等待队列中的下载取消",
            cleanup: { await harness.client.shutdown() }
        )[0]
        guard case .failure(let error) = cancelledResult else {
            return XCTFail("等待中的下载取消后不应成功")
        }
        XCTAssertTrue(error is CancellationError)

        let fifthURL = audioURL(index: 4)
        let fifthTask = harness.downloadTask(from: fifthURL)
        let queuedFifthURL = try await harness.queueEvents.next()
        XCTAssertEqual(queuedFifthURL, fifthURL)
        await harness.client.failDownload(for: firstURLs[0])
        try await harness.client.waitUntilStarted(count: 4)

        let snapshot = await harness.client.snapshot()
        XCTAssertFalse(snapshot.startedURLs.contains(cancelledURL))
        XCTAssertEqual(snapshot.startedURLs.last, fifthURL)
        XCTAssertEqual(snapshot.maximumActiveCount, 3)

        await harness.client.failAllDownloads()
        _ = try await taskResults(
            firstTasks + [fifthTask],
            operation: "等待取消测试收尾",
            cleanup: { await harness.client.shutdown() }
        )
    }

    func testCancellingActiveDownloadReleasesPermitForQueuedFourth() async throws {
        let harness = try makeHarness()
        let firstURLs = (0..<3).map { audioURL(index: $0) }
        let firstTasks = firstURLs.map { harness.downloadTask(from: $0) }
        try await harness.client.waitUntilStarted(count: 3)
        let fourthURL = audioURL(index: 3)
        let fourthTask = harness.downloadTask(from: fourthURL)
        let queuedFourthURL = try await harness.queueEvents.next()
        XCTAssertEqual(queuedFourthURL, fourthURL)

        firstTasks[0].task.cancel()
        _ = try await taskResults(
            [firstTasks[0]],
            operation: "活动下载取消",
            cleanup: { await harness.client.shutdown() }
        )
        try await harness.client.waitUntilStarted(count: 4)

        let snapshot = await harness.client.snapshot()
        XCTAssertEqual(snapshot.startedURLs.last, fourthURL)
        XCTAssertEqual(snapshot.maximumActiveCount, 3)

        await harness.client.failAllDownloads()
        _ = try await taskResults(
            Array(firstTasks.dropFirst()) + [fourthTask],
            operation: "活动取消测试收尾",
            cleanup: { await harness.client.shutdown() }
        )
    }

    func testCancellationAfterPayloadReturnsStopsBeforeDestinationReservation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let temporaryFile = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: temporaryFile)
        }
        let fileStore = try DownloadFileStore(rootURL: root)
        try FileManager.default.removeItem(at: root)
        try Data().write(to: root)
        try makeWaveData().write(to: temporaryFile)
        let sourceURL = URL(string: "https://example.com/cancelled.wav")!
        let response = try XCTUnwrap(HTTPURLResponse(
            url: sourceURL,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "audio/wav"]
        ))
        let musicStore = try LocalMusicStore.inMemory()
        let manager = DownloadManager(
            fileStore: fileStore,
            musicStore: musicStore,
            settingsStore: SettingsStore(defaults: .standard),
            clientFactory: { _ in
                SelfCancellingPayloadDownloadClient(payload: AudioDownloadPayload(
                    temporaryFileURL: temporaryFile,
                    response: response
                ))
            }
        )

        do {
            _ = try await manager.download(from: sourceURL, progress: { _ in })
            XCTFail("payload 返回后已取消的下载不应继续创建目标预留")
        } catch {
            XCTAssertTrue(error is CancellationError, "实际错误：\(error)")
            XCTAssertTrue(try musicStore.fetchTracks().isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryFile.path))
        }
    }

    func testCancellationAfterMetadataReturnsRollsBackFileBeforeIndexWrite() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let temporaryFile = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: temporaryFile)
        }
        try makeWaveData().write(to: temporaryFile)
        let sourceURL = URL(string: "https://example.com/cancelled-after-metadata.wav")!
        let response = try XCTUnwrap(HTTPURLResponse(
            url: sourceURL,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "audio/wav"]
        ))
        let musicStore = try LocalMusicStore.inMemory()
        let manager = DownloadManager(
            fileStore: try DownloadFileStore(rootURL: root),
            musicStore: musicStore,
            settingsStore: SettingsStore(defaults: .standard),
            clientFactory: { _ in
                FixedPayloadDownloadClient(payload: AudioDownloadPayload(
                    temporaryFileURL: temporaryFile,
                    response: response
                ))
            },
            metadataReader: { _, fileName in
                withUnsafeCurrentTask { $0?.cancel() }
                return DownloadedTrackMetadata(
                    id: "cancelled",
                    fileName: fileName,
                    title: "Cancelled",
                    artist: "A",
                    album: "B",
                    duration: 1
                )
            }
        )

        do {
            _ = try await manager.download(from: sourceURL, progress: { _ in })
            XCTFail("元数据返回后已取消的下载不应写入索引")
        } catch {
            XCTAssertTrue(error is CancellationError, "实际错误：\(error)")
            XCTAssertTrue(try musicStore.fetchTracks().isEmpty)
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        }
    }

    func testTemporaryFileCleanupFailurePreservesResponseErrorAndReportsRollbackFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let temporaryFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: temporaryFile)
        }
        try Data("not audio".utf8).write(to: temporaryFile)
        let sourceURL = audioURL(index: 0)
        let response = try XCTUnwrap(HTTPURLResponse(
            url: sourceURL,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "text/html"]
        ))
        let manager = DownloadManager(
            fileStore: try DownloadFileStore(rootURL: root),
            musicStore: try LocalMusicStore.inMemory(),
            settingsStore: SettingsStore(defaults: .standard),
            clientFactory: { _ in
                FixedPayloadDownloadClient(payload: AudioDownloadPayload(
                    temporaryFileURL: temporaryFile,
                    response: response
                ))
            },
            removeFile: { _ in throw ControlledCleanupError.failed }
        )

        do {
            _ = try await manager.download(from: sourceURL, progress: { _ in })
            XCTFail("响应校验和临时文件清理均失败时不应成功")
        } catch let rollback as DownloadRollbackError {
            XCTAssertTrue(rollback.originalError is DownloadError)
            XCTAssertEqual(rollback.cleanupErrors.count, 1)
            XCTAssertTrue(rollback.cleanupErrors[0] is ControlledCleanupError)
            XCTAssertTrue(FileManager.default.fileExists(atPath: temporaryFile.path))
        }
    }

    func testReservationDiscardFailurePreservesCommitErrorAndReportsRollbackFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let missingTemporaryFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = audioURL(index: 0)
        let response = try XCTUnwrap(HTTPURLResponse(
            url: sourceURL,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "audio/mpeg"]
        ))
        let manager = DownloadManager(
            fileStore: try DownloadFileStore(rootURL: root),
            musicStore: try LocalMusicStore.inMemory(),
            settingsStore: SettingsStore(defaults: .standard),
            clientFactory: { _ in
                FixedPayloadDownloadClient(payload: AudioDownloadPayload(
                    temporaryFileURL: missingTemporaryFile,
                    response: response
                ))
            },
            discardReservation: { _ in throw ControlledCleanupError.failed }
        )

        do {
            _ = try await manager.download(from: sourceURL, progress: { _ in })
            XCTFail("提交和 Reservation 回滚均失败时不应成功")
        } catch let rollback as DownloadRollbackError {
            XCTAssertEqual((rollback.originalError as NSError).domain, NSCocoaErrorDomain)
            XCTAssertEqual(rollback.cleanupErrors.count, 1)
            XCTAssertTrue(rollback.cleanupErrors[0] is ControlledCleanupError)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).count, 1)
        }
    }

    func testFinalFileCleanupFailurePreservesMetadataErrorAndReportsRollbackFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let temporaryFile = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: temporaryFile)
        }
        try makeWaveData().write(to: temporaryFile)
        let sourceURL = URL(string: "https://example.com/metadata-fails.wav")!
        let response = try XCTUnwrap(HTTPURLResponse(
            url: sourceURL,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "audio/wav"]
        ))
        let musicStore = try LocalMusicStore.inMemory()
        let manager = DownloadManager(
            fileStore: try DownloadFileStore(rootURL: root),
            musicStore: musicStore,
            settingsStore: SettingsStore(defaults: .standard),
            clientFactory: { _ in
                FixedPayloadDownloadClient(payload: AudioDownloadPayload(
                    temporaryFileURL: temporaryFile,
                    response: response
                ))
            },
            metadataReader: { _, _ in throw ControlledDownloadError.failed },
            removeFile: { _ in throw ControlledCleanupError.failed }
        )

        do {
            _ = try await manager.download(from: sourceURL, progress: { _ in })
            XCTFail("元数据和最终文件回滚均失败时不应成功")
        } catch let rollback as DownloadRollbackError {
            XCTAssertTrue(rollback.originalError is ControlledDownloadError)
            XCTAssertEqual(rollback.cleanupErrors.count, 1)
            XCTAssertTrue(rollback.cleanupErrors[0] is ControlledCleanupError)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["metadata-fails.wav"])
            XCTAssertTrue(try musicStore.fetchTracks().isEmpty)
        }
    }

    func testSessionConfigurationUsesCellularDownloadSetting() async throws {
        let suiteName = "DownloadManagerConcurrencyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = SettingsStore(defaults: defaults)
        let client = ImmediateFailureDownloadClient()
        var receivedAllowsCellularAccess = [Bool]()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = DownloadManager(
            fileStore: try DownloadFileStore(rootURL: root),
            musicStore: try LocalMusicStore.inMemory(),
            settingsStore: settings,
            clientFactory: { configuration in
                receivedAllowsCellularAccess.append(configuration.allowsCellularAccess)
                return client
            }
        )

        for (index, value) in [false, true].enumerated() {
            settings.allowsCellularDownloads = value
            do {
                _ = try await manager.download(from: audioURL(index: index), progress: { _ in })
                XCTFail("受控客户端应让下载失败")
            } catch is ControlledDownloadError {
                // 预期失败只用于在真实网络调用前观察会话配置。
            }
        }

        XCTAssertEqual(receivedAllowsCellularAccess, [false, true])
    }

    func testInvalidDownloadedMediaRemovesTemporaryAndReservedFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let temporaryFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: temporaryFile)
        }
        try Data("not audio".utf8).write(to: temporaryFile)
        let sourceURL = audioURL(index: 0)
        let response = try XCTUnwrap(HTTPURLResponse(
            url: sourceURL,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "audio/mpeg"]
        ))
        let musicStore = try LocalMusicStore.inMemory()
        let manager = DownloadManager(
            fileStore: try DownloadFileStore(rootURL: root),
            musicStore: musicStore,
            settingsStore: SettingsStore(defaults: .standard),
            clientFactory: { _ in
                FixedPayloadDownloadClient(payload: AudioDownloadPayload(
                    temporaryFileURL: temporaryFile,
                    response: response
                ))
            }
        )

        do {
            _ = try await manager.download(from: sourceURL, progress: { _ in })
            XCTFail("无效媒体不应写入索引")
        } catch {
            XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryFile.path))
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
            XCTAssertTrue(try musicStore.fetchTracks().isEmpty)
        }
    }

    func testValidDownloadedMediaKeepsFileAndWritesIndex() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let temporaryFile = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: temporaryFile)
        }
        try makeWaveData().write(to: temporaryFile)
        let sourceURL = URL(string: "https://example.com/track.wav")!
        let response = try XCTUnwrap(HTTPURLResponse(
            url: sourceURL,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "audio/wav"]
        ))
        let musicStore = try LocalMusicStore.inMemory()
        let manager = DownloadManager(
            fileStore: try DownloadFileStore(rootURL: root),
            musicStore: musicStore,
            settingsStore: SettingsStore(defaults: .standard),
            clientFactory: { _ in
                FixedPayloadDownloadClient(payload: AudioDownloadPayload(
                    temporaryFileURL: temporaryFile,
                    response: response
                ))
            }
        )

        let track = try await manager.download(from: sourceURL, progress: { _ in })

        XCTAssertEqual(track.title, "track")
        XCTAssertEqual(track.artist, MusicTrack.unknownArtist)
        XCTAssertEqual(track.album, MusicTrack.unknownAlbum)
        XCTAssertEqual(track.source, .downloaded(fileName: "track.wav"))
        XCTAssertGreaterThan(track.duration, 0)
        XCTAssertEqual(try musicStore.fetchTracks().map(\.id), [track.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("track.wav").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryFile.path))
    }

    private func makeHarness() throws -> DownloadHarness {
        let suiteName = "DownloadManagerConcurrencyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let client = ControllableAudioDownloadClient()
        let queueEvents = QueueEventProbe()
        let manager = DownloadManager(
            fileStore: try DownloadFileStore(rootURL: root),
            musicStore: try LocalMusicStore.inMemory(),
            settingsStore: SettingsStore(defaults: defaults),
            clientFactory: { _ in client },
            queueObserver: { queueEvents.record($0) }
        )
        let harness = DownloadHarness(
            manager: manager,
            client: client,
            queueEvents: queueEvents,
            rootURL: root,
            defaultsSuiteName: suiteName
        )
        addTeardownBlock {
            try await harness.cleanup()
        }
        return harness
    }

    private func audioURL(index: Int) -> URL {
        URL(string: "https://example.com/song-\(index).mp3")!
    }

    private func makeWaveData() -> Data {
        let sampleRate: UInt32 = 8_000
        let sampleCount: UInt32 = 800
        let dataSize = sampleCount * 2
        var data = Data("RIFF".utf8)
        data.appendLittleEndian(UInt32(36) + dataSize)
        data.append(Data("WAVEfmt ".utf8))
        data.appendLittleEndian(UInt32(16))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(sampleRate)
        data.appendLittleEndian(sampleRate * 2)
        data.appendLittleEndian(UInt16(2))
        data.appendLittleEndian(UInt16(16))
        data.append(Data("data".utf8))
        data.appendLittleEndian(dataSize)
        data.append(Data(repeating: 0, count: Int(dataSize)))
        return data
    }
}

@MainActor
private final class DownloadHarness: @unchecked Sendable {
    let manager: DownloadManager
    let client: ControllableAudioDownloadClient
    let queueEvents: QueueEventProbe
    let rootURL: URL
    let defaultsSuiteName: String
    private var tasks = [ObservedTask<MusicTrack>]()

    @MainActor
    init(
        manager: DownloadManager,
        client: ControllableAudioDownloadClient,
        queueEvents: QueueEventProbe,
        rootURL: URL,
        defaultsSuiteName: String
    ) {
        self.manager = manager
        self.client = client
        self.queueEvents = queueEvents
        self.rootURL = rootURL
        self.defaultsSuiteName = defaultsSuiteName
    }

    func downloadTask(from url: URL) -> ObservedTask<MusicTrack> {
        let task = ObservedTask<MusicTrack>(description: "下载任务：\(url.lastPathComponent)") { [manager] in
            try await manager.download(from: url, progress: { _ in })
        }
        tasks.append(task)
        return task
    }

    func cleanup() async throws {
        tasks.forEach { $0.task.cancel() }
        await client.shutdown()
        let result = await waitForExpectations(
            tasks.map { $0.completion.expectation() },
            timeout: 2
        )
        guard result == .completed else {
            throw TestTimeoutError(operation: "测试 teardown 收束全部下载任务")
        }
        try? FileManager.default.removeItem(at: rootURL)
        UserDefaults(suiteName: defaultsSuiteName)?.removePersistentDomain(forName: defaultsSuiteName)
    }
}

private enum ControlledDownloadError: Error {
    case failed
}

private enum ControlledCleanupError: Error {
    case failed
}

private struct TestTimeoutError: LocalizedError {
    let operation: String

    var errorDescription: String? {
        "等待超时：\(operation)"
    }
}

private actor ManualTaskGate {
    private var isOpen = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

private struct ObservedTask<Success: Sendable> {
    let task: Task<Success, Error>
    let completion: CompletionSignal<Success>

    @MainActor
    init(
        description: String,
        operation: @escaping @MainActor @Sendable () async throws -> Success
    ) {
        let completion = CompletionSignal<Success>(description: description)
        self.completion = completion
        task = Task { @MainActor in
            let result: Result<Success, Error>
            do {
                result = .success(try await operation())
            } catch {
                result = .failure(error)
            }
            completion.finish(with: result)
            return try result.get()
        }
    }
}

private final class CompletionSignal<Value>: @unchecked Sendable {
    private let description: String
    private let lock = NSLock()
    private var result: Result<Value, Error>?
    private var expectations = [XCTestExpectation]()

    init(description: String) {
        self.description = description
    }

    func expectation() -> XCTestExpectation {
        let expectation = XCTestExpectation(description: description)
        lock.lock()
        if result != nil {
            lock.unlock()
            expectation.fulfill()
        } else {
            expectations.append(expectation)
            lock.unlock()
        }
        return expectation
    }

    func finish(with result: Result<Value, Error>) {
        let pending: [XCTestExpectation]
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }
        self.result = result
        pending = expectations
        expectations.removeAll()
        lock.unlock()
        pending.forEach { $0.fulfill() }
    }

    func value() -> Result<Value, Error> {
        lock.lock()
        defer { lock.unlock() }
        return result ?? .failure(CancellationError())
    }
}

private final class TaskHandleBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    func store(_ task: Task<Void, Never>) {
        lock.lock()
        self.task = task
        lock.unlock()
    }

    func take() -> Task<Void, Never>? {
        lock.lock()
        let current = task
        task = nil
        lock.unlock()
        return current
    }
}

private func waitForExpectations(
    _ expectations: [XCTestExpectation],
    timeout: TimeInterval
) async -> XCTWaiter.Result {
    let waiter = Task.detached {
        await XCTWaiter.fulfillment(of: expectations, timeout: timeout)
    }
    return await waiter.value
}

@MainActor
private func taskResults<Success: Sendable>(
    _ tasks: [ObservedTask<Success>],
    operation: String,
    timeout: TimeInterval = 2,
    cleanup: @escaping @MainActor () async -> Void
) async throws -> [Result<Success, Error>] {
    let completion = await waitForExpectations(
        tasks.map { $0.completion.expectation() },
        timeout: timeout
    )
    guard completion == .completed else {
        tasks.forEach { $0.task.cancel() }
        await cleanup()
        let cleanupCompletion = await waitForExpectations(
            tasks.map { $0.completion.expectation() },
            timeout: 2
        )
        guard cleanupCompletion == .completed else {
            throw TestTimeoutError(operation: "\(operation)；取消与 cleanup 后任务仍未结束")
        }
        throw TestTimeoutError(operation: operation)
    }

    return tasks.map { $0.completion.value() }
}

private final class QueueEventProbe: @unchecked Sendable {
    private let events = TestEventProbe<URL>()

    func record(_ url: URL) {
        events.record(url)
    }

    func next(timeout: TimeInterval = 2) async throws -> URL {
        try await events.next(
            operation: "下载进入 FIFO 等待队列",
            timeout: timeout,
            matching: { _ in true }
        )
    }
}

private final class StartedCountProbe: @unchecked Sendable {
    private let events = TestEventProbe<Int>()

    func record(_ count: Int) {
        events.record(count)
    }

    func wait(for count: Int, timeout: TimeInterval) async throws {
        _ = try await events.next(
            operation: "client 开始第 \(count) 个下载",
            timeout: timeout,
            matching: { $0 >= count }
        )
    }
}

private final class TestEventProbe<Value>: @unchecked Sendable {
    private struct Waiter {
        let id: UUID
        let matches: (Value) -> Bool
        let completion: CompletionSignal<Value>
    }

    private let lock = NSLock()
    private var pending = [Value]()
    private var waiters = [Waiter]()

    func record(_ value: Value) {
        let waiter: Waiter?
        lock.lock()
        if let index = waiters.firstIndex(where: { $0.matches(value) }) {
            waiter = waiters.remove(at: index)
        } else {
            pending.append(value)
            waiter = nil
        }
        lock.unlock()
        waiter?.completion.finish(with: .success(value))
    }

    func next(
        operation: String,
        timeout: TimeInterval,
        matching matches: @escaping (Value) -> Bool
    ) async throws -> Value {
        let waiter = Waiter(
            id: UUID(),
            matches: matches,
            completion: CompletionSignal(description: operation)
        )
        install(waiter)
        let waitResult = await withTaskCancellationHandler {
            await waitForExpectations(
                [waiter.completion.expectation()],
                timeout: timeout
            )
        } onCancel: {
            resolve(waiter.id, with: CancellationError())
        }
        if waitResult != .completed {
            resolve(waiter.id, with: TestTimeoutError(operation: operation))
        }
        return try waiter.completion.value().get()
    }

    private func install(_ waiter: Waiter) {
        let immediate: Result<Value, Error>?
        lock.lock()
        if let index = pending.firstIndex(where: waiter.matches) {
            immediate = .success(pending.remove(at: index))
        } else if Task.isCancelled {
            immediate = .failure(CancellationError())
        } else {
            waiters.append(waiter)
            immediate = nil
        }
        lock.unlock()
        immediate.map { waiter.completion.finish(with: $0) }
    }

    private func resolve(_ id: UUID, with error: Error) {
        let waiter: Waiter?
        lock.lock()
        if let index = waiters.firstIndex(where: { $0.id == id }) {
            waiter = waiters.remove(at: index)
        } else {
            waiter = nil
        }
        lock.unlock()
        waiter?.completion.finish(with: .failure(error))
    }
}

private actor ControllableAudioDownloadClient: AudioDownloadClient {
    struct Snapshot {
        let startedURLs: [URL]
        let maximumActiveCount: Int
    }

    private var continuations = [URL: CheckedContinuation<AudioDownloadPayload, Error>]()
    private var startedURLs = [URL]()
    private var activeCount = 0
    private var maximumActiveCount = 0
    private var isShutDown = false
    private let startedProbe = StartedCountProbe()

    func download(
        from url: URL,
        progress: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws -> AudioDownloadPayload {
        guard !isShutDown else { throw ControlledDownloadError.failed }
        activeCount += 1
        maximumActiveCount = max(maximumActiveCount, activeCount)
        startedURLs.append(url)
        startedProbe.record(startedURLs.count)
        defer { activeCount -= 1 }

        let cancellationTask = TaskHandleBox()
        let result: Result<AudioDownloadPayload, Error>
        do {
            let payload = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    continuations[url] = continuation
                }
            } onCancel: {
                cancellationTask.store(Task { await self.cancelDownload(for: url) })
            }
            result = .success(payload)
        } catch {
            result = .failure(error)
        }
        if let task = cancellationTask.take() {
            await task.value
        }
        return try result.get()
    }

    func waitUntilStarted(count: Int, timeout: TimeInterval = 2) async throws {
        try await startedProbe.wait(for: count, timeout: timeout)
    }

    func failDownload(for url: URL) {
        continuations.removeValue(forKey: url)?.resume(throwing: ControlledDownloadError.failed)
    }

    func failAllDownloads() {
        let pending = Array(continuations.values)
        continuations.removeAll()
        pending.forEach { $0.resume(throwing: ControlledDownloadError.failed) }
    }

    func shutdown() {
        isShutDown = true
        failAllDownloads()
    }

    func snapshot() -> Snapshot {
        Snapshot(startedURLs: startedURLs, maximumActiveCount: maximumActiveCount)
    }

    private func cancelDownload(for url: URL) {
        continuations.removeValue(forKey: url)?.resume(throwing: CancellationError())
    }

}

private struct ImmediateFailureDownloadClient: AudioDownloadClient {
    func download(
        from url: URL,
        progress: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws -> AudioDownloadPayload {
        throw ControlledDownloadError.failed
    }
}

private struct FixedPayloadDownloadClient: AudioDownloadClient {
    let payload: AudioDownloadPayload

    func download(
        from url: URL,
        progress: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws -> AudioDownloadPayload {
        payload
    }
}

private struct SelfCancellingPayloadDownloadClient: AudioDownloadClient {
    let payload: AudioDownloadPayload

    func download(
        from url: URL,
        progress: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws -> AudioDownloadPayload {
        withUnsafeCurrentTask { task in
            task?.cancel()
        }
        return payload
    }
}

private extension Data {
    mutating func appendLittleEndian<Value: FixedWidthInteger>(_ value: Value) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { bytes in
            append(contentsOf: bytes)
        }
    }
}
