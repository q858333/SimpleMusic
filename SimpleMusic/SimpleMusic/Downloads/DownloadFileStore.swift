import Darwin
import Foundation

/// 下载存储层拒绝无效、跨实例或已消费的预留。
enum DownloadFileStoreError: Error {
    case invalidReservation
    case reservationConsumed
    case invalidFileName
    case fileNotFound
    case notRegularFile
    case playbackLeaseCreationFailed
    case playbackLeaseCopyFailed
}

/// 播放期间持有不可替换的受控副本；显式 release 与析构清理均幂等。
nonisolated final class PlaybackFileLease {
    let fileURL: URL
    private let lock = NSLock()
    private var isReleased = false

    fileprivate init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func release() {
        lock.lock()
        guard !isReleased else {
            lock.unlock()
            return
        }
        isReleased = true
        lock.unlock()
        try? FileManager.default.removeItem(at: fileURL)
    }

    deinit {
        release()
    }
}

/// 下载文件的受限目录存储；所有建议文件名都会归一为根目录内的单一文件名。
struct DownloadFileStore {
    fileprivate final class Owner {}

    /// 下载目标的不可伪造凭证；调用方只能读取路径，不能自行构造或重置状态。
    final class Reservation {
        fileprivate enum State {
            case live
            case committed
            case discarded
        }

        let destinationURL: URL
        fileprivate let owner: Owner
        fileprivate let lock = NSLock()
        fileprivate var state = State.live

        fileprivate init(destinationURL: URL, owner: Owner) {
            self.destinationURL = destinationURL
            self.owner = owner
        }
    }

    private let rootURL: URL
    private let owner = Owner()

    init(rootURL: URL) throws {
        self.rootURL = rootURL
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    /// 通过 O_NOFOLLOW 固定源 inode，再复制到唯一 staging 文件，避免校验后路径被替换。
    func playbackLease(for fileName: String) throws -> PlaybackFileLease {
        let trimmedName = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty,
              !fileName.contains("/"),
              !fileName.contains("\\"),
              fileName != ".",
              fileName != ".." else {
            throw DownloadFileStoreError.invalidFileName
        }

        let standardizedRoot = rootURL.standardizedFileURL
        let candidate = standardizedRoot.appendingPathComponent(fileName, isDirectory: false).standardizedFileURL
        guard candidate.deletingLastPathComponent() == standardizedRoot else {
            throw DownloadFileStoreError.invalidFileName
        }

        let sourceDescriptor = Darwin.open(candidate.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard sourceDescriptor >= 0 else {
            if errno == ENOENT {
                throw DownloadFileStoreError.fileNotFound
            }
            throw DownloadFileStoreError.notRegularFile
        }
        defer { Darwin.close(sourceDescriptor) }

        var sourceStatus = stat()
        guard fstat(sourceDescriptor, &sourceStatus) == 0,
              (sourceStatus.st_mode & S_IFMT) == S_IFREG else {
            throw DownloadFileStoreError.notRegularFile
        }

        let pathExtension = candidate.pathExtension
        let stagingName = pathExtension.isEmpty
            ? ".playback-\(UUID().uuidString)"
            : ".playback-\(UUID().uuidString).\(pathExtension)"
        let stagingURL = standardizedRoot.appendingPathComponent(stagingName, isDirectory: false)
        let destinationDescriptor = Darwin.open(
            stagingURL.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard destinationDescriptor >= 0 else {
            throw DownloadFileStoreError.playbackLeaseCreationFailed
        }

        do {
            defer { Darwin.close(destinationDescriptor) }
            try copy(from: sourceDescriptor, to: destinationDescriptor)
        } catch {
            try? FileManager.default.removeItem(at: stagingURL)
            throw error
        }
        return PlaybackFileLease(fileURL: stagingURL)
    }

    /// 原子创建空占位文件；Task 4 持有返回凭证，并在成功或失败路径恰好消费一次。
    func reserveDestination(suggestedName: String) throws -> Reservation {
        let name = safeFileName(from: suggestedName)
        let baseName = (name as NSString).deletingPathExtension
        let pathExtension = (name as NSString).pathExtension
        var candidateURL = rootURL.appendingPathComponent(name, isDirectory: false)

        while true {
            do {
                try Data().write(to: candidateURL, options: .withoutOverwriting)
                return Reservation(destinationURL: candidateURL, owner: owner)
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                let suffix = UUID().uuidString.prefix(8)
                let candidateName = pathExtension.isEmpty
                    ? "\(baseName)-\(suffix)"
                    : "\(baseName)-\(suffix).\(pathExtension)"
                candidateURL = rootURL.appendingPathComponent(candidateName, isDirectory: false)
            }
        }
    }

    /// 仅凭本实例创建且仍存活的预留提交；成功后凭证不可再次使用。
    func commit(temporaryFileURL: URL, reservation: Reservation) throws {
        try consume(reservation, as: .committed) { destinationURL in
            _ = try FileManager.default.replaceItemAt(destinationURL, withItemAt: temporaryFileURL)
        }
    }

    /// 下载失败或取消时消费预留；已提交的最终内容不会被后续 discard 删除。
    func discard(reservation: Reservation) throws {
        try consume(reservation, as: .discarded) { destinationURL in
            try FileManager.default.removeItem(at: destinationURL)
        }
    }

    private func consume(
        _ reservation: Reservation,
        as finalState: Reservation.State,
        operation: (URL) throws -> Void
    ) throws {
        guard reservation.owner === owner else {
            throw DownloadFileStoreError.invalidReservation
        }

        // 状态检查、文件操作和终态写入必须同锁完成，避免同一凭证被并发消费两次。
        reservation.lock.lock()
        defer { reservation.lock.unlock() }
        guard reservation.state == .live else {
            throw DownloadFileStoreError.reservationConsumed
        }

        try operation(reservation.destinationURL)
        reservation.state = finalState
    }

    private func safeFileName(from suggestedName: String) -> String {
        let leafName = (suggestedName as NSString).lastPathComponent
        let forbidden = CharacterSet(charactersIn: ":\\?%*|\"<>")
        let cleaned = leafName
            .components(separatedBy: forbidden)
            .joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return cleaned.isEmpty || cleaned == "." || cleaned == ".." ? "audio" : cleaned
    }

    private func copy(from sourceDescriptor: Int32, to destinationDescriptor: Int32) throws {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)

        while true {
            let bytesRead = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(sourceDescriptor, bytes.baseAddress, bytes.count)
            }
            if bytesRead == 0 { return }
            if bytesRead < 0 {
                if errno == EINTR { continue }
                throw DownloadFileStoreError.playbackLeaseCopyFailed
            }

            var offset = 0
            while offset < bytesRead {
                let bytesWritten = buffer.withUnsafeBytes { bytes in
                    Darwin.write(
                        destinationDescriptor,
                        bytes.baseAddress?.advanced(by: offset),
                        bytesRead - offset
                    )
                }
                if bytesWritten < 0 {
                    if errno == EINTR { continue }
                    throw DownloadFileStoreError.playbackLeaseCopyFailed
                }
                guard bytesWritten > 0 else {
                    throw DownloadFileStoreError.playbackLeaseCopyFailed
                }
                offset += bytesWritten
            }
        }
    }
}
