import Foundation

/// 下载存储层拒绝无效、跨实例或已消费的预留。
enum DownloadFileStoreError: Error {
    case invalidReservation
    case reservationConsumed
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
}
