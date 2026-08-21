import Foundation

@MainActor
protocol DownloadQueuePersisting: AnyObject {
    func load() throws -> [DownloadJob]
    func save(_ jobs: [DownloadJob]) throws
}

@MainActor
final class DownloadQueueStore: DownloadQueuePersisting {
    private let fileURL: URL?
    private var memoryJobs: [DownloadJob]
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(fileURL: URL?, initialJobs: [DownloadJob] = []) {
        self.fileURL = fileURL
        memoryJobs = initialJobs
        encoder.outputFormatting = [.sortedKeys]
    }

    func load() throws -> [DownloadJob] {
        guard let fileURL else { return memoryJobs }
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        return try decoder.decode([DownloadJob].self, from: Data(contentsOf: fileURL))
    }

    func save(_ jobs: [DownloadJob]) throws {
        guard let fileURL else {
            memoryJobs = jobs
            return
        }
        try encoder.encode(jobs).write(to: fileURL, options: .atomic)
    }

    static func applicationSupport(fileManager: FileManager = .default) throws -> DownloadQueueStore {
        guard let applicationSupportURL = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw CocoaError(.fileNoSuchFile)
        }

        let directoryURL = applicationSupportURL.appendingPathComponent("SimpleMusic", isDirectory: true)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return DownloadQueueStore(fileURL: directoryURL.appendingPathComponent("download-queue.json"))
    }
}
