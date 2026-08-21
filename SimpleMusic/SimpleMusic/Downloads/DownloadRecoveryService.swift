import Darwin
import Foundation

enum DownloadRecoveryServiceError: Error, Equatable {
    case temporaryFileAccessFailed(errno: Int32)
}

struct DownloadRecoveryService {
    typealias TemporaryEntryStatusReader = (
        String,
        UnsafeMutablePointer<stat>
    ) -> (result: Int32, errorCode: Int32)
    typealias TemporaryEntryUnlinker = (String) -> (result: Int32, errorCode: Int32)

    let fileStore: DownloadFileStore
    let musicStore: LocalMusicStore
    let temporaryDirectory: URL
    private let temporaryEntryStatusReader: TemporaryEntryStatusReader
    private let temporaryEntryUnlinker: TemporaryEntryUnlinker

    init(
        fileStore: DownloadFileStore,
        musicStore: LocalMusicStore,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        temporaryEntryStatusReader: @escaping TemporaryEntryStatusReader = { path, status in
            let result = Darwin.lstat(path, status)
            return (result, result < 0 ? errno : 0)
        },
        temporaryEntryUnlinker: @escaping TemporaryEntryUnlinker = { path in
            let result = Darwin.unlink(path)
            return (result, result < 0 ? errno : 0)
        }
    ) {
        self.fileStore = fileStore
        self.musicStore = musicStore
        self.temporaryDirectory = temporaryDirectory
        self.temporaryEntryStatusReader = temporaryEntryStatusReader
        self.temporaryEntryUnlinker = temporaryEntryUnlinker
    }

    func reconcile(fileName: String) async throws -> DownloadQueue.RecoveryDisposition {
        if try await musicStore.contains(fileName: fileName) {
            return .indexed
        }
        do {
            try fileStore.removeFile(named: fileName)
        } catch DownloadFileStoreError.fileNotFound {
            // 文件已不存在等价于清理完成；安全或 I/O 错误必须继续上抛。
        }
        return .cleaned
    }

    func cleanupRetainedTemporaryFiles() throws {
        for url in try FileManager.default.contentsOfDirectory(
            at: temporaryDirectory,
            includingPropertiesForKeys: nil
        ) where url.lastPathComponent.hasPrefix("SimpleMusicDownload-") {
            var status = stat()
            let statusResult = temporaryEntryStatusReader(url.path, &status)
            guard statusResult.result == 0 else {
                if statusResult.errorCode == ENOENT { continue }
                throw DownloadRecoveryServiceError.temporaryFileAccessFailed(
                    errno: statusResult.errorCode
                )
            }
            let entryType = status.st_mode & S_IFMT
            guard entryType == S_IFREG || entryType == S_IFLNK else { continue }

            let unlinkResult = temporaryEntryUnlinker(url.path)
            guard unlinkResult.result == 0 else {
                if unlinkResult.errorCode == ENOENT { continue }
                throw DownloadRecoveryServiceError.temporaryFileAccessFailed(
                    errno: unlinkResult.errorCode
                )
            }
        }
    }
}
