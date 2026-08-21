import Foundation

struct DownloadRecoveryService {
    let fileStore: DownloadFileStore
    let musicStore: LocalMusicStore
    var temporaryDirectory = FileManager.default.temporaryDirectory

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
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        ) where url.lastPathComponent.hasPrefix("SimpleMusicDownload-") {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true || values.isSymbolicLink == true else { continue }
            try FileManager.default.removeItem(at: url)
        }
    }
}
