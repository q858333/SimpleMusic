import AVFoundation
import Foundation

/// URLResponse 是 Foundation 只读响应对象；在并发传输边界按不可变值携带。
struct AudioDownloadPayload: @unchecked Sendable {
    let temporaryFileURL: URL
    let response: URLResponse
}

/// 网络下载边界允许测试替换传输层，同时保留真实响应验证和文件事务。
nonisolated protocol AudioDownloadClient: Sendable {
    func download(
        from url: URL,
        progress: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws -> AudioDownloadPayload
}

/// URLSession 的真实实现通过 task delegate 把下载进度切回主 actor。
nonisolated final class URLSessionAudioDownloadClient: AudioDownloadClient, @unchecked Sendable {
    private let session: URLSession

    init(configuration: URLSessionConfiguration) {
        session = URLSession(configuration: configuration)
    }

    func download(
        from url: URL,
        progress: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws -> AudioDownloadPayload {
        let delegate = DownloadProgressDelegate(progress: progress)
        let (temporaryURL, response) = try await session.download(from: url, delegate: delegate)
        return AudioDownloadPayload(temporaryFileURL: temporaryURL, response: response)
    }
}

private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let progress: @MainActor @Sendable (Double) -> Void

    init(progress: @escaping @MainActor @Sendable (Double) -> Void) {
        self.progress = progress
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {}

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let value = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        Task { @MainActor [progress] in
            progress(value)
        }
    }
}

/// 下载编排严格维持“网络临时文件→受限目录→媒体元数据→索引”的提交顺序。
@MainActor
final class DownloadManager {
    typealias ClientFactory = (URLSessionConfiguration) -> any AudioDownloadClient

    private let fileStore: DownloadFileStore
    private let musicStore: LocalMusicStore
    private let settingsStore: SettingsStore
    private let clientFactory: ClientFactory
    private let validator = AudioDownloadValidator()
    private let permitPool = DownloadPermitPool(limit: 3)
    private let fileManager: FileManager

    init(
        fileStore: DownloadFileStore,
        musicStore: LocalMusicStore,
        settingsStore: SettingsStore,
        fileManager: FileManager = .default,
        clientFactory: @escaping ClientFactory = { configuration in
            URLSessionAudioDownloadClient(configuration: configuration)
        }
    ) {
        self.fileStore = fileStore
        self.musicStore = musicStore
        self.settingsStore = settingsStore
        self.fileManager = fileManager
        self.clientFactory = clientFactory
    }

    func download(
        from url: URL,
        progress: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws -> MusicTrack {
        try validator.validate(url: url)
        return try await permitPool.withPermit { [self] in
            try await performDownload(from: url, progress: progress)
        }
    }

    private func performDownload(
        from url: URL,
        progress: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws -> MusicTrack {
        let configuration = URLSessionConfiguration.default
        configuration.allowsCellularAccess = settingsStore.allowsCellularDownloads
        let payload = try await clientFactory(configuration).download(from: url, progress: progress)
        defer { try? fileManager.removeItem(at: payload.temporaryFileURL) }

        try validator.validate(response: payload.response, sourceURL: url)
        let reservation = try fileStore.reserveDestination(suggestedName: url.lastPathComponent)
        var committed = false
        var indexed = false
        defer {
            if !indexed {
                if committed {
                    try? fileManager.removeItem(at: reservation.destinationURL)
                } else {
                    try? fileStore.discard(reservation: reservation)
                }
            }
        }

        try fileStore.commit(temporaryFileURL: payload.temporaryFileURL, reservation: reservation)
        committed = true
        let metadata = try await readMetadata(
            at: reservation.destinationURL,
            fileName: reservation.destinationURL.lastPathComponent
        )
        let track = try musicStore.insert(metadata)
        indexed = true
        return track
    }

    private func readMetadata(at fileURL: URL, fileName: String) async throws -> DownloadedTrackMetadata {
        let asset = AVURLAsset(url: fileURL)
        let duration = try await asset.load(.duration).seconds
        let commonMetadata = try await asset.load(.commonMetadata)
        let title = await metadataValue(.commonIdentifierTitle, in: commonMetadata)
            ?? fileURL.deletingPathExtension().lastPathComponent
        let artist = await metadataValue(.commonIdentifierArtist, in: commonMetadata)
            ?? MusicTrack.unknownArtist
        let album = await metadataValue(.commonIdentifierAlbumName, in: commonMetadata)
            ?? MusicTrack.unknownAlbum

        return DownloadedTrackMetadata(
            id: UUID().uuidString,
            fileName: fileName,
            title: title,
            artist: artist,
            album: album,
            duration: duration.isFinite ? max(0, duration) : 0
        )
    }

    private func metadataValue(
        _ identifier: AVMetadataIdentifier,
        in items: [AVMetadataItem]
    ) async -> String? {
        guard let item = AVMetadataItem.metadataItems(
            from: items,
            filteredByIdentifier: identifier
        ).first else {
            return nil
        }
        return try? await item.load(.stringValue)
    }
}

/// actor 串行维护名额与等待队列；取消只移除对应等待者，不改变活动计数。
private actor DownloadPermitPool {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private let limit: Int
    private var activeCount = 0
    private var waiters = [Waiter]()

    init(limit: Int) {
        self.limit = limit
    }

    func withPermit<Value: Sendable>(
        operation: @Sendable () async throws -> Value
    ) async throws -> Value {
        try await acquire()
        defer { release() }
        try Task.checkCancellation()
        return try await operation()
    }

    private func acquire() async throws {
        try Task.checkCancellation()
        if activeCount < limit {
            activeCount += 1
            return
        }

        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters.append(Waiter(id: id, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: id) }
        }
    }

    private func release() {
        if waiters.isEmpty {
            activeCount -= 1
        } else {
            waiters.removeFirst().continuation.resume()
        }
    }

    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}
