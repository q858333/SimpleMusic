import MediaPlayer
import UIKit

/// 系统媒体库的值类型边界，避免领域模型直接依赖 `MPMediaItem`。
struct SystemTrackMetadata: Sendable {
    let persistentID: UInt64
    let title: String?
    let artist: String?
    let album: String?
    let duration: TimeInterval
    let artworkData: Data?
}

/// 负责权限申请与系统音乐资料库查询；播放所需系统对象仅在这里按持久 ID 取回。
@MainActor
final class MusicLibraryService {
    typealias MetadataQuery = @Sendable () throws -> [SystemTrackMetadata]

    private let authorizationStatusProvider: () -> MPMediaLibraryAuthorizationStatus
    private let metadataQuery: MetadataQuery

    init(
        authorizationStatusProvider: @escaping () -> MPMediaLibraryAuthorizationStatus = {
            MPMediaLibrary.authorizationStatus()
        },
        metadataQuery: MetadataQuery? = nil
    ) {
        self.authorizationStatusProvider = authorizationStatusProvider
        self.metadataQuery = metadataQuery ?? Self.queryMetadata
    }

    var authorizationStatus: MPMediaLibraryAuthorizationStatus {
        authorizationStatusProvider()
    }

    func requestAuthorization() async -> MPMediaLibraryAuthorizationStatus {
        await withCheckedContinuation { continuation in
            MPMediaLibrary.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    func fetchTracks() throws -> [MusicTrack] {
        // 未获授权时不触碰媒体库查询，模拟器与首次启动均可安全返回空列表。
        guard authorizationStatus == .authorized else { return [] }

        return try metadataQuery().map(Self.makeTrack)
    }

    /// 正式资料库刷新只在主线程检查权限；媒体查询和系统对象读取全部留在后台任务。
    func fetchTracksAsync() async throws -> [MusicTrack] {
        guard authorizationStatus == .authorized else { return [] }

        let query = metadataQuery
        let metadata = try await Task.detached(priority: .userInitiated) {
            try query()
        }.value
        guard authorizationStatus == .authorized else { return [] }
        return metadata.map(Self.makeTrack)
    }

    func mediaItem(for persistentID: UInt64) -> MPMediaItem? {
        let predicate = MPMediaPropertyPredicate(
            value: NSNumber(value: persistentID),
            forProperty: MPMediaItemPropertyPersistentID
        )
        return MPMediaQuery(filterPredicates: [predicate]).items?.first
    }

    static func makeTrack(from metadata: SystemTrackMetadata) -> MusicTrack {
        let identifier = "system-\(metadata.persistentID)"
        return MusicTrack(
            id: identifier,
            title: displayValue(metadata.title) ?? identifier,
            artist: displayValue(metadata.artist) ?? MusicTrack.unknownArtist,
            album: displayValue(metadata.album) ?? MusicTrack.unknownAlbum,
            duration: metadata.duration,
            artworkData: metadata.artworkData,
            source: .system(persistentID: metadata.persistentID)
        )
    }

    nonisolated private static func queryMetadata() throws -> [SystemTrackMetadata] {
        (MPMediaQuery.songs().items ?? []).map(metadata)
    }

    nonisolated private static func metadata(from item: MPMediaItem) -> SystemTrackMetadata {
        let artworkData: Data?
        if let artwork = item.artwork {
            artworkData = artwork.image(at: artwork.bounds.size)?.pngData()
        } else {
            artworkData = nil
        }

        return SystemTrackMetadata(
            persistentID: item.persistentID,
            title: item.title,
            artist: item.artist,
            album: item.albumTitle,
            duration: item.playbackDuration,
            artworkData: artworkData
        )
    }

    nonisolated private static func displayValue(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return value
    }
}
