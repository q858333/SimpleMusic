import Foundation
import XCTest
@testable import SimpleMusic

@MainActor
final class DownloadManagerConcurrencyTests: XCTestCase {
    func testFourthDownloadStartsOnlyAfterOneOfThreeActiveDownloadsFinishes() async throws {
        let harness = try makeHarness()
        defer { harness.cleanup() }
        let firstURLs = (0..<3).map { audioURL(index: $0) }
        let firstTasks = firstURLs.map { url in
            Task { try await harness.manager.download(from: url, progress: { _ in }) }
        }
        await harness.client.waitUntilStarted(count: 3)

        let fourthURL = audioURL(index: 3)
        let fourthTask = Task {
            try await harness.manager.download(from: fourthURL, progress: { _ in })
        }
        await settleScheduling()

        var snapshot = await harness.client.snapshot()
        XCTAssertEqual(snapshot.startedURLs.count, 3)
        XCTAssertEqual(snapshot.maximumActiveCount, 3)

        await harness.client.failDownload(for: firstURLs[0])
        await harness.client.waitUntilStarted(count: 4)

        snapshot = await harness.client.snapshot()
        XCTAssertEqual(snapshot.startedURLs.last, fourthURL)
        XCTAssertEqual(snapshot.maximumActiveCount, 3)

        await harness.client.failAllDownloads()
        for task in firstTasks + [fourthTask] {
            _ = await task.result
        }
    }

    func testQueuedDownloadsStartInSubmissionOrder() async throws {
        let harness = try makeHarness()
        defer { harness.cleanup() }
        let firstURLs = (0..<3).map { audioURL(index: $0) }
        let firstTasks = firstURLs.map { url in
            Task { try await harness.manager.download(from: url, progress: { _ in }) }
        }
        await harness.client.waitUntilStarted(count: 3)

        let fourthURL = audioURL(index: 3)
        let fourthTask = Task {
            try await harness.manager.download(from: fourthURL, progress: { _ in })
        }
        await settleScheduling()
        let fifthURL = audioURL(index: 4)
        let fifthTask = Task {
            try await harness.manager.download(from: fifthURL, progress: { _ in })
        }
        await settleScheduling()

        await harness.client.failDownload(for: firstURLs[0])
        await harness.client.waitUntilStarted(count: 4)
        var snapshot = await harness.client.snapshot()
        XCTAssertEqual(snapshot.startedURLs.last, fourthURL)

        await harness.client.failDownload(for: fourthURL)
        await harness.client.waitUntilStarted(count: 5)
        snapshot = await harness.client.snapshot()
        XCTAssertEqual(snapshot.startedURLs.last, fifthURL)

        await harness.client.failAllDownloads()
        for task in firstTasks + [fourthTask, fifthTask] {
            _ = await task.result
        }
    }

    func testCancellingQueuedFourthDownloadDoesNotConsumePermitOrBlockFifth() async throws {
        let harness = try makeHarness()
        defer { harness.cleanup() }
        let firstURLs = (0..<3).map { audioURL(index: $0) }
        let firstTasks = firstURLs.map { url in
            Task { try await harness.manager.download(from: url, progress: { _ in }) }
        }
        await harness.client.waitUntilStarted(count: 3)

        let cancelledURL = audioURL(index: 3)
        let cancelledTask = Task {
            try await harness.manager.download(from: cancelledURL, progress: { _ in })
        }
        await settleScheduling()
        cancelledTask.cancel()
        let cancelledResult = await cancelledTask.result
        guard case .failure(let error) = cancelledResult else {
            return XCTFail("等待中的下载取消后不应成功")
        }
        XCTAssertTrue(error is CancellationError)

        let fifthURL = audioURL(index: 4)
        let fifthTask = Task {
            try await harness.manager.download(from: fifthURL, progress: { _ in })
        }
        await settleScheduling()
        await harness.client.failDownload(for: firstURLs[0])
        await harness.client.waitUntilStarted(count: 4)

        let snapshot = await harness.client.snapshot()
        XCTAssertFalse(snapshot.startedURLs.contains(cancelledURL))
        XCTAssertEqual(snapshot.startedURLs.last, fifthURL)
        XCTAssertEqual(snapshot.maximumActiveCount, 3)

        await harness.client.failAllDownloads()
        for task in firstTasks + [fifthTask] {
            _ = await task.result
        }
    }

    func testCancellingActiveDownloadReleasesPermitForQueuedFourth() async throws {
        let harness = try makeHarness()
        defer { harness.cleanup() }
        let firstURLs = (0..<3).map { audioURL(index: $0) }
        let firstTasks = firstURLs.map { url in
            Task { try await harness.manager.download(from: url, progress: { _ in }) }
        }
        await harness.client.waitUntilStarted(count: 3)
        let fourthURL = audioURL(index: 3)
        let fourthTask = Task {
            try await harness.manager.download(from: fourthURL, progress: { _ in })
        }
        await settleScheduling()

        firstTasks[0].cancel()
        _ = await firstTasks[0].result
        await harness.client.waitUntilStarted(count: 4)

        let snapshot = await harness.client.snapshot()
        XCTAssertEqual(snapshot.startedURLs.last, fourthURL)
        XCTAssertEqual(snapshot.maximumActiveCount, 3)

        await harness.client.failAllDownloads()
        for task in Array(firstTasks.dropFirst()) + [fourthTask] {
            _ = await task.result
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
        let manager = DownloadManager(
            fileStore: try DownloadFileStore(rootURL: root),
            musicStore: try LocalMusicStore.inMemory(),
            settingsStore: SettingsStore(defaults: defaults),
            clientFactory: { _ in client }
        )
        return DownloadHarness(manager: manager, client: client, rootURL: root, defaultsSuiteName: suiteName)
    }

    private func audioURL(index: Int) -> URL {
        URL(string: "https://example.com/song-\(index).mp3")!
    }

    private func settleScheduling() async {
        for _ in 0..<20 {
            await Task.yield()
        }
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
    let rootURL: URL
    let defaultsSuiteName: String

    @MainActor
    init(
        manager: DownloadManager,
        client: ControllableAudioDownloadClient,
        rootURL: URL,
        defaultsSuiteName: String
    ) {
        self.manager = manager
        self.client = client
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

private actor ControllableAudioDownloadClient: AudioDownloadClient {
    struct Snapshot {
        let startedURLs: [URL]
        let maximumActiveCount: Int
    }

    private var continuations = [URL: CheckedContinuation<AudioDownloadPayload, Error>]()
    private var startedURLs = [URL]()
    private var activeCount = 0
    private var maximumActiveCount = 0
    private var startWaiters = [(count: Int, continuation: CheckedContinuation<Void, Never>)]()

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

    func waitUntilStarted(count: Int) async {
        guard startedURLs.count < count else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append((count, continuation))
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

    private func resumeSatisfiedStartWaiters() {
        var remaining = [(count: Int, continuation: CheckedContinuation<Void, Never>)]()
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

private extension Data {
    mutating func appendLittleEndian<Value: FixedWidthInteger>(_ value: Value) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { bytes in
            append(contentsOf: bytes)
        }
    }
}
