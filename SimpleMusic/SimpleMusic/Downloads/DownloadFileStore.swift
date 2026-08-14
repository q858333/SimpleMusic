import Foundation

/// 下载文件的受限目录存储；所有建议文件名都会归一为根目录内的单一文件名。
struct DownloadFileStore {
    private let rootURL: URL

    init(rootURL: URL) throws {
        self.rootURL = rootURL
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    /// 发生同名冲突时追加短 UUID，保留扩展名以便后续按媒体类型读取且不覆盖已有文件。
    func destinationURL(suggestedName: String) -> URL {
        let name = safeFileName(from: suggestedName)
        let initialURL = rootURL.appendingPathComponent(name, isDirectory: false)

        guard !FileManager.default.fileExists(atPath: initialURL.path) else {
            return initialURL
        }

        let baseName = (name as NSString).deletingPathExtension
        let pathExtension = (name as NSString).pathExtension
        var candidateURL: URL
        repeat {
            let suffix = UUID().uuidString.prefix(8)
            let candidateName = pathExtension.isEmpty
                ? "\(baseName)-\(suffix)"
                : "\(baseName)-\(suffix).\(pathExtension)"
            candidateURL = rootURL.appendingPathComponent(candidateName, isDirectory: false)
        } while FileManager.default.fileExists(atPath: candidateURL.path)

        return candidateURL
    }

    private func safeFileName(from suggestedName: String) -> String {
        let leafName = (suggestedName as NSString).lastPathComponent
        let forbidden = CharacterSet(charactersIn: ":\\?%*|\"<>")
        let cleaned = leafName.components(separatedBy: forbidden).joined(separator: "_")
        return cleaned.isEmpty || cleaned == "." || cleaned == ".." ? "audio" : cleaned
    }
}
