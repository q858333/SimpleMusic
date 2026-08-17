import Foundation
import XCTest
@testable import SimpleMusic

@MainActor
final class DownloadManagerConcurrencyTests: XCTestCase {
    func testTaskResultTimeoutReturnsAndCancelsUnfinishedTask() async throws {
        let gate = ManualTaskGate()
        let task = Task<Void, Error> {
            await gate.wait()
        }

        do {
            _ = try await taskResult(task, operation: "受控未完成任务", timeout: 0.01)
            XCTFail("未完成任务必须在截止时间返回超时")
        } catch let error as TestTimeoutError {
            XCTAssertEqual(error.operation, "受控未完成任务")
            XCTAssertTrue(task.isCancelled)
        }

        await gate.open()
        _ = try await taskResult(task, operation: "释放受控任务", timeout: 1)
    }

    func testCancellationBeforeStartWaiterEnqueueResumesWithoutHanging() async throws {
        let gate = ManualTaskGate()
        let waitingTask = Task<Void, Error> {
            await gate.wait()
            try await withCheckedThrowingContinuation { continuation in
                XCTAssertTrue(resumeCancellationIfNeeded(continuation))
            }
        }
        waitingTask.cancel()
        await gate.open()

        let result = try await taskResult(
            waitingTask,
            operation: "入队前取消 started waiter",
            timeout: 0.2
        )
        guard case .failure(let error) = result else {
            return XCTFail("入队前取消的 waiter 不应成功")
        }
        XCTAssertTrue(error is CancellationError)
    }

    func testFourthDownloadStartsOnlyAfterOneOfThreeActiveDownloadsFinishes() async throws {
        let harness = try makeHarness()
        defer { harness.cleanup() }
        let firstURLs = (0..<3).map { audioURL(index: $0) }
        let firstTasks = firstURLs.map { url in
            Task { try await harness.manager.download(from: url, progress: { _ in }) }
        }
        try await harness.client.waitUntilStarted(count: 3)

        let fourthURL = audioURL(index: 3)
        let fourthTask = Task {
            try await harness.manager.download(from: fourthURL, progress: { _ in })
        }
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
        try await waitForTaskResults(
            firstTasks + [fourthTask],
            operation: "并发上限测试收尾"
        )
    }

    func testQueuedDownloadsStartInSubmissionOrder() async throws {
        let harness = try makeHarness()
        defer { harness.cleanup() }
        let firstURLs = (0..<3).map { audioURL(index: $0) }
        let firstTasks = firstURLs.map { url in
            Task { try await harness.manager.download(from: url, progress: { _ in }) }
        }
        try await harness.client.waitUntilStarted(count: 3)

        let fourthURL = audioURL(index: 3)
        let fourthTask = Task {
            try await harness.manager.download(from: fourthURL, progress: { _ in })
        }
        let queuedFourthURL = try await harness.queueEvents.next()
        XCTAssertEqual(queuedFourthURL, fourthURL)
        let fifthURL = audioURL(index: 4)
        let fifthTask = Task {
            try await harness.manager.download(from: fifthURL, progress: { _ in })
        }
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
        try await waitForTaskResults(
            firstTasks + [fourthTask, fifthTask],
            operation: "FIFO 测试收尾"
        )
    }

    func testCancellingQueuedFourthDownloadDoesNotConsumePermitOrBlockFifth() async throws {
        let harness = try makeHarness()
        defer { harness.cleanup() }
        let firstURLs = (0..<3).map { audioURL(index: $0) }
        let firstTasks = firstURLs.map { url in
            Task { try await harness.manager.download(from: url, progress: { _ in }) }
        }
        try await harness.client.waitUntilStarted(count: 3)

        let cancelledURL = audioURL(index: 3)
        let cancelledTask = Task {
            try await harness.manager.download(from: cancelledURL, progress: { _ in })
        }
        let queuedCancelledURL = try await harness.queueEvents.next()
        XCTAssertEqual(queuedCancelledURL, cancelledURL)
        cancelledTask.cancel()
        let cancelledResult = try await taskResult(
            cancelledTask,
            operation: "等待队列中的下载取消"
        )
        guard case .failure(let error) = cancelledResult else {
            return XCTFail("等待中的下载取消后不应成功")
        }
        XCTAssertTrue(error is CancellationError)

        let fifthURL = audioURL(index: 4)
        let fifthTask = Task {
            try await harness.manager.download(from: fifthURL, progress: { _ in })
        }
        let queuedFifthURL = try await harness.queueEvents.next()
        XCTAssertEqual(queuedFifthURL, fifthURL)
        await harness.client.failDownload(for: firstURLs[0])
        try await harness.client.waitUntilStarted(count: 4)

        let snapshot = await harness.client.snapshot()
        XCTAssertFalse(snapshot.startedURLs.contains(cancelledURL))
        XCTAssertEqual(snapshot.startedURLs.last, fifthURL)
        XCTAssertEqual(snapshot.maximumActiveCount, 3)

        await harness.client.failAllDownloads()
        try await waitForTaskResults(
            firstTasks + [fifthTask],
            operation: "等待取消测试收尾"
        )
    }

    func testCancellingActiveDownloadReleasesPermitForQueuedFourth() async throws {
        let harness = try makeHarness()
        defer { harness.cleanup() }
        let firstURLs = (0..<3).map { audioURL(index: $0) }
        let firstTasks = firstURLs.map { url in
            Task { try await harness.manager.download(from: url, progress: { _ in }) }
        }
        try await harness.client.waitUntilStarted(count: 3)
        let fourthURL = audioURL(index: 3)
        let fourthTask = Task {
            try await harness.manager.download(from: fourthURL, progress: { _ in })
        }
        let queuedFourthURL = try await harness.queueEvents.next()
        XCTAssertEqual(queuedFourthURL, fourthURL)

        firstTasks[0].cancel()
        _ = try await taskResult(
            firstTasks[0],
            operation: "活动下载取消"
        )
        try await harness.client.waitUntilStarted(count: 4)

        let snapshot = await harness.client.snapshot()
        XCTAssertEqual(snapshot.startedURLs.last, fourthURL)
        XCTAssertEqual(snapshot.maximumActiveCount, 3)

        await harness.client.failAllDownloads()
        try await waitForTaskResults(
            Array(firstTasks.dropFirst()) + [fourthTask],
            operation: "活动取消测试收尾"
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
        return DownloadHarness(
            manager: manager,
            client: client,
            queueEvents: queueEvents,
            rootURL: root,
            defaultsSuiteName: suiteName
        )
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

private struct DownloadHarness {
    let manager: DownloadManager
    let client: ControllableAudioDownloadClient
    let queueEvents: QueueEventProbe
    let rootURL: URL
    let defaultsSuiteName: String

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

    func cleanup() {
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

private func withTestTimeout<Value: Sendable>(
    _ operationDescription: String,
    seconds: TimeInterval = 2,
    cancellationAction: @escaping @Sendable () -> Void = {},
    operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
    let (stream, streamContinuation) = AsyncStream<Result<Value, Error>>.makeStream()
    let operationTask = Task {
        do {
            streamContinuation.yield(.success(try await operation()))
        } catch {
            streamContinuation.yield(.failure(error))
        }
    }
    let timeoutTask = Task {
        do {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        } catch {
            return
        }
        streamContinuation.yield(.failure(TestTimeoutError(operation: operationDescription)))
        cancellationAction()
    }
    defer {
        streamContinuation.finish()
        operationTask.cancel()
        timeoutTask.cancel()
    }

    return try await withTaskCancellationHandler {
        var iterator = stream.makeAsyncIterator()
        guard let result = await iterator.next() else { throw CancellationError() }
        return try result.get()
    } onCancel: {
        cancellationAction()
        streamContinuation.finish()
    }
}

private func taskResult<Success: Sendable>(
    _ task: Task<Success, Error>,
    operation: String,
    timeout: TimeInterval = 2
) async throws -> Result<Success, Error> {
    try await withTestTimeout(
        operation,
        seconds: timeout,
        cancellationAction: { task.cancel() }
    ) {
        await task.result
    }
}

private func waitForTaskResults<Success: Sendable>(
    _ tasks: [Task<Success, Error>],
    operation: String,
    timeout: TimeInterval = 2
) async throws {
    do {
        for (index, task) in tasks.enumerated() {
            _ = try await taskResult(
                task,
                operation: "\(operation) #\(index + 1)",
                timeout: timeout
            )
        }
    } catch {
        tasks.forEach { $0.cancel() }
        throw error
    }
}

private func resumeCancellationIfNeeded(
    _ continuation: CheckedContinuation<Void, Error>
) -> Bool {
    guard Task.isCancelled else { return false }
    continuation.resume(throwing: CancellationError())
    return true
}

private final class QueueEventProbe: @unchecked Sendable {
    private let continuation: AsyncStream<URL>.Continuation
    private let reader: QueueEventReader

    init() {
        var streamContinuation: AsyncStream<URL>.Continuation!
        let stream = AsyncStream<URL> { streamContinuation = $0 }
        continuation = streamContinuation
        reader = QueueEventReader(iterator: stream.makeAsyncIterator())
    }

    func record(_ url: URL) {
        continuation.yield(url)
    }

    func next(timeout: TimeInterval = 2) async throws -> URL {
        try await withTestTimeout("下载进入 FIFO 等待队列", seconds: timeout) { [reader] in
            guard let url = await reader.next() else {
                throw CancellationError()
            }
            return url
        }
    }
}

private actor QueueEventReader {
    private var iterator: AsyncStream<URL>.AsyncIterator

    init(iterator: AsyncStream<URL>.AsyncIterator) {
        self.iterator = iterator
    }

    func next() async -> URL? {
        var currentIterator = iterator
        let value = await currentIterator.next()
        iterator = currentIterator
        return value
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
    private struct StartWaiter {
        let id: UUID
        let count: Int
        let continuation: CheckedContinuation<Void, Error>
    }

    private var startWaiters = [StartWaiter]()

    func download(
        from url: URL,
        progress: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws -> AudioDownloadPayload {
        activeCount += 1
        maximumActiveCount = max(maximumActiveCount, activeCount)
        startedURLs.append(url)
        resumeSatisfiedStartWaiters()
        defer { activeCount -= 1 }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                continuations[url] = continuation
            }
        } onCancel: {
            Task { await self.cancelDownload(for: url) }
        }
    }

    func waitUntilStarted(count: Int, timeout: TimeInterval = 2) async throws {
        try await withTestTimeout("client 开始第 \(count) 个下载", seconds: timeout) { [self] in
            try await waitForStarted(count: count)
        }
    }

    func failDownload(for url: URL) {
        continuations.removeValue(forKey: url)?.resume(throwing: ControlledDownloadError.failed)
    }

    func failAllDownloads() {
        let pending = Array(continuations.values)
        continuations.removeAll()
        pending.forEach { $0.resume(throwing: ControlledDownloadError.failed) }
    }

    func snapshot() -> Snapshot {
        Snapshot(startedURLs: startedURLs, maximumActiveCount: maximumActiveCount)
    }

    private func cancelDownload(for url: URL) {
        continuations.removeValue(forKey: url)?.resume(throwing: CancellationError())
    }

    private func waitForStarted(count: Int) async throws {
        try Task.checkCancellation()
        guard startedURLs.count < count else { return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // 取消若早于 continuation 安装则同步恢复；安装后的竞态由 actor 队列串行裁决。
                if !resumeCancellationIfNeeded(continuation) {
                    startWaiters.append(StartWaiter(id: id, count: count, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelStartWaiter(id: id) }
        }
    }

    private func cancelStartWaiter(id: UUID) {
        guard let index = startWaiters.firstIndex(where: { $0.id == id }) else { return }
        startWaiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func resumeSatisfiedStartWaiters() {
        var remaining = [StartWaiter]()
        for waiter in startWaiters {
            if startedURLs.count >= waiter.count {
                waiter.continuation.resume()
            } else {
                remaining.append(waiter)
            }
        }
        startWaiters = remaining
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
