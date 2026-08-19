import AVFoundation
import Foundation

enum LocalMusicCatalogError: Error {
    case notDownloadedTrack
}

/// 把 Core Data 索引与受限下载目录组合成 UI 唯一可见的本地歌曲来源。
final class LocalMusicCatalog: @unchecked Sendable {
    typealias PlayabilityCheck = @MainActor @Sendable (URL) async throws -> Bool
    typealias LeaseProvider = @Sendable (String) throws -> PlaybackFileLease

    private let musicStore: LocalMusicStore
    private let fileStore: DownloadFileStore
    private let leaseProvider: LeaseProvider
    private let playabilityCheck: PlayabilityCheck

    init(
        musicStore: LocalMusicStore,
        fileStore: DownloadFileStore,
        leaseProvider: LeaseProvider? = nil,
        playabilityCheck: @escaping PlayabilityCheck = { url in
            let asset = AVURLAsset(url: url)
            return try await asset.load(.isPlayable)
        }
    ) {
        self.musicStore = musicStore
        self.fileStore = fileStore
        self.leaseProvider = leaseProvider ?? { fileName in
            try fileStore.playbackLease(for: fileName)
        }
        self.playabilityCheck = playabilityCheck
    }

    func loadTracks() async throws -> [MusicTrack] {
        let indexedTracks = try await musicStore.fetchTracksAsync()
        var playableTracks = [MusicTrack]()

        for track in indexedTracks {
            guard case let .downloaded(fileName) = track.source else { continue }

            let lease: PlaybackFileLease
            do {
                lease = try leaseProvider(fileName)
            } catch let error as DownloadFileStoreError {
                switch error {
                case .fileNotFound, .notRegularFile, .emptyFile:
                    break
                default:
                    // staging 创建或复制等瞬时故障不得让仍有效的用户索引丢失。
                    throw error
                }
                // 自动协调只清除不可播放文件的索引，不触碰下载目录中的其他节点。
                try musicStore.delete(id: track.id)
                continue
            } catch {
                throw error
            }

            let isPlayable: Bool
            do {
                isPlayable = try await playabilityCheck(lease.fileURL)
            } catch {
                lease.release()
                throw error
            }
            lease.release()
            if isPlayable {
                playableTracks.append(track)
            } else {
                try musicStore.delete(id: track.id)
            }
        }
        return playableTracks
    }

    func delete(_ track: MusicTrack) async throws {
        guard case let .downloaded(fileName) = track.source else {
            throw LocalMusicCatalogError.notDownloadedTrack
        }

        do {
            // 仅删除受控下载根中的叶子；符号链接只删除链接本身，不会跟随目标。
            try fileStore.removeFile(named: fileName)
        } catch DownloadFileStoreError.fileNotFound {
            // 文件已缺失时仍清理死索引，使用户删除操作保持幂等。
        }
        try musicStore.delete(id: track.id)
    }
}
