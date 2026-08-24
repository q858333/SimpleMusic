import AVFoundation
import Combine
import Foundation
import Network

nonisolated enum DownloadNetworkStatus: Equatable, Sendable {
    case unknown
    case unavailable
    case wifi
    case cellular
    case other
}

@MainActor
protocol DownloadNetworkStatusProviding: AnyObject {
    var currentStatus: DownloadNetworkStatus { get }
    var statusPublisher: AnyPublisher<DownloadNetworkStatus, Never> { get }
}

/// 统一缓存系统当前实际使用的网络接口，下载入口和下载执行阶段共享同一份状态。
@MainActor
final class DownloadNetworkMonitor: DownloadNetworkStatusProviding {
    private let monitor: NWPathMonitor
    private let monitorQueue = DispatchQueue(label: "SimpleMusic.DownloadNetworkMonitor")
    private let subject = CurrentValueSubject<DownloadNetworkStatus, Never>(.unknown)

    var currentStatus: DownloadNetworkStatus { subject.value }
    var statusPublisher: AnyPublisher<DownloadNetworkStatus, Never> {
        subject.removeDuplicates().eraseToAnyPublisher()
    }

    init(monitor: NWPathMonitor = NWPathMonitor()) {
        self.monitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            let status = Self.status(for: path)
            Task { @MainActor [weak self] in
                self?.subject.send(status)
            }
        }
        monitor.start(queue: monitorQueue)
    }

    deinit {
        monitor.cancel()
    }

    private nonisolated static func status(for path: NWPath) -> DownloadNetworkStatus {
        guard path.status == .satisfied else { return .unavailable }
        if path.usesInterfaceType(.cellular) { return .cellular }
        if path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet) { return .wifi }
        return .other
    }
}

nonisolated enum DownloadPolicyError: Error, Equatable, Sendable {
    case cellularAccessDisabled
}

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
    private let configuration: URLSessionConfiguration

    init(configuration: URLSessionConfiguration) {
        self.configuration = configuration
    }

    func download(
        from url: URL,
        progress: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws -> AudioDownloadPayload {
        let transfer = DownloadProgressDelegate(configuration: configuration, progress: progress)
        return try await transfer.download(from: url)
    }
}

/// 下载主阶段失败且回滚也失败时，同时暴露两类错误，避免清理故障被静默丢弃。
struct DownloadRollbackError: Error {
    let originalError: Error
    let cleanupErrors: [Error]
}

private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let configuration: URLSessionConfiguration
    private let progress: @MainActor @Sendable (Double) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<AudioDownloadPayload, Error>?
    private var task: URLSessionDownloadTask?
    private var retainedTemporaryURL: URL?
    private var fileMoveError: Error?
    private var cancellationRequested = false

    init(
        configuration: URLSessionConfiguration,
        progress: @escaping @MainActor @Sendable (Double) -> Void
    ) {
        self.configuration = configuration
        self.progress = progress
    }

    func download(from url: URL) async throws -> AudioDownloadPayload {
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let task = session.downloadTask(with: url)
                lock.lock()
                guard !cancellationRequested else {
                    lock.unlock()
                    session.invalidateAndCancel()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.task = task
                self.continuation = continuation
                lock.unlock()
                task.resume()
            }
        } onCancel: { [weak self] in
            self?.cancel()
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let retainedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SimpleMusicDownload-\(UUID().uuidString)", isDirectory: false)
        do {
            // 系统回调返回后会清理 location，先移到应用持有的临时路径再恢复 async 调用方。
            try FileManager.default.moveItem(at: location, to: retainedURL)
            lock.lock()
            retainedTemporaryURL = retainedURL
            lock.unlock()
        } catch {
            lock.lock()
            fileMoveError = error
            lock.unlock()
        }
    }

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

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        self.task = nil
        let retainedTemporaryURL = self.retainedTemporaryURL
        let fileMoveError = self.fileMoveError
        let cancellationRequested = self.cancellationRequested
        lock.unlock()

        session.finishTasksAndInvalidate()
        if cancellationRequested || (error as? URLError)?.code == .cancelled {
            if let retainedTemporaryURL {
                try? FileManager.default.removeItem(at: retainedTemporaryURL)
            }
            continuation.resume(throwing: CancellationError())
        } else if let error {
            if let retainedTemporaryURL {
                try? FileManager.default.removeItem(at: retainedTemporaryURL)
            }
            continuation.resume(throwing: error)
        } else if let fileMoveError {
            continuation.resume(throwing: fileMoveError)
        } else if let retainedTemporaryURL, let response = task.response {
            continuation.resume(returning: AudioDownloadPayload(
                temporaryFileURL: retainedTemporaryURL,
                response: response
            ))
        } else {
            continuation.resume(throwing: URLError(.cannotCreateFile))
        }
    }

    private func cancel() {
        lock.lock()
        cancellationRequested = true
        let task = self.task
        lock.unlock()
        task?.cancel()
    }
}

/// 下载编排严格维持“网络临时文件→受限目录→媒体元数据→索引”的提交顺序。
@MainActor
final class DownloadManager {
    typealias ClientFactory = (URLSessionConfiguration) -> any AudioDownloadClient
    typealias MetadataReader = (URL, String) async throws -> DownloadedTrackMetadata
    typealias ReservationObserver = @MainActor @Sendable (String) throws -> Void

    private let fileStore: DownloadFileStore
    private let musicStore: LocalMusicStore
    private let settingsStore: SettingsStore
    private let networkStatusProvider: (any DownloadNetworkStatusProviding)?
    private let clientFactory: ClientFactory
    private let metadataReader: MetadataReader
    private let removeFile: (URL) throws -> Void
    private let discardReservation: (DownloadFileStore.Reservation) throws -> Void
    private let queueObserver: @Sendable (URL) -> Void
    private let validator = AudioDownloadValidator()
    private let permitPool = DownloadPermitPool(limit: 3)
    private let fileManager: FileManager

    init(
        fileStore: DownloadFileStore,
        musicStore: LocalMusicStore,
        settingsStore: SettingsStore,
        networkStatusProvider: (any DownloadNetworkStatusProviding)? = nil,
        fileManager: FileManager = .default,
        clientFactory: @escaping ClientFactory = { configuration in
            URLSessionAudioDownloadClient(configuration: configuration)
        },
        metadataReader: MetadataReader? = nil,
        removeFile: @escaping (URL) throws -> Void = { url in
            try FileManager.default.removeItem(at: url)
        },
        discardReservation: ((DownloadFileStore.Reservation) throws -> Void)? = nil,
        queueObserver: @escaping @Sendable (URL) -> Void = { _ in }
    ) {
        self.fileStore = fileStore
        self.musicStore = musicStore
        self.settingsStore = settingsStore
        self.networkStatusProvider = networkStatusProvider
        self.fileManager = fileManager
        self.clientFactory = clientFactory
        self.metadataReader = metadataReader ?? Self.readMetadata
        self.removeFile = removeFile
        self.discardReservation = discardReservation ?? { reservation in
            try fileStore.discard(reservation: reservation)
        }
        self.queueObserver = queueObserver
    }

    func download(
        from url: URL,
        progress: @escaping @MainActor @Sendable (Double) -> Void,
        onReservation: @escaping ReservationObserver = { _ in }
    ) async throws -> MusicTrack {
        try validator.validate(url: url)
        return try await permitPool.withPermit(onQueued: { [queueObserver] in
            queueObserver(url)
        }) { [self] in
            try await performDownload(
                from: url,
                progress: progress,
                onReservation: onReservation
            )
        }
    }

    private func performDownload(
        from url: URL,
        progress: @escaping @MainActor @Sendable (Double) -> Void,
        onReservation: @escaping ReservationObserver
    ) async throws -> MusicTrack {
        if !settingsStore.allowsCellularDownloads,
           networkStatusProvider?.currentStatus == .cellular {
            throw DownloadPolicyError.cellularAccessDisabled
        }
        let configuration = URLSessionConfiguration.default
        configuration.allowsCellularAccess = settingsStore.allowsCellularDownloads
        let payload = try await clientFactory(configuration).download(from: url, progress: progress)
        var reservation: DownloadFileStore.Reservation?
        var committed = false

        do {
            try Task.checkCancellation()
            try validator.validate(response: payload.response, sourceURL: url)
            let newReservation = try fileStore.reserveDestination(suggestedName: url.lastPathComponent)
            reservation = newReservation
            try onReservation(newReservation.destinationURL.lastPathComponent)

            try fileStore.commit(temporaryFileURL: payload.temporaryFileURL, reservation: newReservation)
            committed = true
            let metadata = try await metadataReader(
                newReservation.destinationURL,
                newReservation.destinationURL.lastPathComponent
            )
            // 元数据读取是最后一个挂起点；写索引前必须重新响应取消。
            try Task.checkCancellation()
            return try musicStore.insert(metadata.recording(sourceURL: url))
        } catch {
            // 文件与 Reservation 构成同一回滚单元；收集全部清理错误后保留原始阶段错误。
            let rollbackError = rollback(
                payload: payload,
                reservation: reservation,
                committed: committed,
                originalError: error
            )
            throw rollbackError
        }
    }

    private func rollback(
        payload: AudioDownloadPayload,
        reservation: DownloadFileStore.Reservation?,
        committed: Bool,
        originalError: Error
    ) -> Error {
        var cleanupErrors = [Error]()

        if let reservation {
            do {
                if committed {
                    try removeIfPresent(at: reservation.destinationURL)
                } else {
                    try discardReservation(reservation)
                }
            } catch {
                cleanupErrors.append(error)
            }
        }

        do {
            try removeIfPresent(at: payload.temporaryFileURL)
        } catch {
            cleanupErrors.append(error)
        }

        guard !cleanupErrors.isEmpty else { return originalError }
        return DownloadRollbackError(originalError: originalError, cleanupErrors: cleanupErrors)
    }

    private func removeIfPresent(at url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        try removeFile(url)
    }

    private static func readMetadata(at fileURL: URL, fileName: String) async throws -> DownloadedTrackMetadata {
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

    private static func metadataValue(
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
        onQueued: @Sendable () -> Void,
        operation: @Sendable () async throws -> Value
    ) async throws -> Value {
        try await acquire(onQueued: onQueued)
        defer { release() }
        try Task.checkCancellation()
        return try await operation()
    }

    private func acquire(onQueued: @Sendable () -> Void) async throws {
        try Task.checkCancellation()
        if activeCount < limit {
            activeCount += 1
            return
        }

        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters.append(Waiter(id: id, continuation: continuation))
                // 观察点在 waiter 入队后同步发出，测试和诊断无需猜测调度时序。
                onQueued()
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
