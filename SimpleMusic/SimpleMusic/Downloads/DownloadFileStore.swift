import Foundation

/// 下载存储层拒绝不属于其预留目录的目标路径。
enum DownloadFileStoreError: Error {
    case invalidReservation
}

/// 下载文件的受限目录存储；所有建议文件名都会归一为根目录内的单一文件名。
struct DownloadFileStore {
    private let rootURL: URL

    init(rootURL: URL) throws {
        self.rootURL = rootURL
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    /// 原子创建空占位文件；调用方拥有该预留，成功时调用 `commit`，失败或取消时调用 `discardReservation`。
    func destinationURL(suggestedName: String) throws -> URL {
        let name = safeFileName(from: suggestedName)
        let baseName = (name as NSString).deletingPathExtension
        let pathExtension = (name as NSString).pathExtension
        var candidateURL = rootURL.appendingPathComponent(name, isDirectory: false)

        while true {
            do {
                try Data().write(to: candidateURL, options: .withoutOverwriting)
                return candidateURL
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                let suffix = UUID().uuidString.prefix(8)
                let candidateName = pathExtension.isEmpty
                    ? "\(baseName)-\(suffix)"
                    : "\(baseName)-\(suffix).\(pathExtension)"
                candidateURL = rootURL.appendingPathComponent(candidateName, isDirectory: false)
            }
        }
    }

    /// 仅替换本存储创建的占位文件，保留预留的唯一性并将临时下载结果移入私有目录。
    func commit(temporaryFileURL: URL, toReservedURL destinationURL: URL) throws {
        guard isReservedDestination(destinationURL) else {
            throw DownloadFileStoreError.invalidReservation
        }

        _ = try FileManager.default.replaceItemAt(destinationURL, withItemAt: temporaryFileURL)
    }

    /// 下载失败或取消时由预留的调用方调用；拒绝删除存储根目录以外的文件。
    func discardReservation(at destinationURL: URL) throws {
        guard isReservedDestination(destinationURL) else {
            throw DownloadFileStoreError.invalidReservation
        }

        try FileManager.default.removeItem(at: destinationURL)
    }

    private func isReservedDestination(_ destinationURL: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: destinationURL.path) else {
            return false
        }

        return destinationURL.deletingLastPathComponent().standardizedFileURL == rootURL.standardizedFileURL
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
}
