import CoreData

/// 下载完成后写入索引所需的不可变元数据，不持有文件系统对象。
struct DownloadedTrackMetadata {
    let id: String
    let fileName: String
    let title: String
    let artist: String
    let album: String
    let duration: TimeInterval
    let createdAt: Date
    let lastPlayedAt: Date?
    let sourceURL: URL?

    init(
        id: String,
        fileName: String,
        title: String,
        artist: String,
        album: String,
        duration: TimeInterval,
        createdAt: Date = Date(),
        lastPlayedAt: Date? = nil,
        sourceURL: URL? = nil
    ) {
        self.id = id
        self.fileName = fileName
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.createdAt = createdAt
        self.lastPlayedAt = lastPlayedAt
        self.sourceURL = sourceURL
    }

    /// 媒体元数据来自落盘文件，来源地址由下载编排在提交索引前补充。
    func recording(sourceURL: URL) -> DownloadedTrackMetadata {
        DownloadedTrackMetadata(
            id: id,
            fileName: fileName,
            title: title,
            artist: artist,
            album: album,
            duration: duration,
            createdAt: createdAt,
            lastPlayedAt: lastPlayedAt,
            sourceURL: sourceURL
        )
    }
}

/// Core Data 对象只在所属 context 内读取；跨执行器仅传递不可变值快照。
struct LocalTrackRecord: Sendable {
    let id: String
    let fileName: String
    let title: String
    let artist: String
    let album: String
    let duration: TimeInterval
}

/// Core Data 下载索引的事务边界；文件的创建和删除由 DownloadManager 负责。
final class LocalMusicStore: @unchecked Sendable {
    typealias BackgroundQuery = @Sendable (NSManagedObjectContext) throws -> [LocalTrackRecord]

    private let container: NSPersistentContainer
    private let backgroundQuery: BackgroundQuery
    private var context: NSManagedObjectContext { container.viewContext }

    init(container: NSPersistentContainer, backgroundQuery: BackgroundQuery? = nil) {
        self.container = container
        self.backgroundQuery = backgroundQuery ?? Self.fetchRecords
    }

    static func inMemory() throws -> LocalMusicStore {
        let container = NSPersistentContainer(name: "SimpleMusic")
        let description = NSPersistentStoreDescription()
        description.type = NSInMemoryStoreType
        description.shouldAddStoreAsynchronously = false
        container.persistentStoreDescriptions = [description]

        var loadingError: Error?
        container.loadPersistentStores { _, error in
            loadingError = error
        }
        if let loadingError {
            throw loadingError
        }
        return LocalMusicStore(container: container)
    }

    func fetchTracks() throws -> [MusicTrack] {
        try context.performAndWait {
            try Self.fetchRecords(in: context).map(Self.makeTrack)
        }
    }

    /// 使用独立 background context 查询；continuation 在单个 Result 路径上恰好恢复一次。
    func fetchTracksAsync() async throws -> [MusicTrack] {
        let query = backgroundQuery
        let records: [LocalTrackRecord] = try await withCheckedThrowingContinuation { continuation in
            container.performBackgroundTask { context in
                continuation.resume(with: Result { try query(context) })
            }
        }
        return records.map(Self.makeTrack)
    }

    func contains(fileName: String) async throws -> Bool {
        try await fetchTracksAsync().contains { track in
            guard case let .downloaded(indexedName) = track.source else { return false }
            return indexedName == fileName
        }
    }

    func insert(_ metadata: DownloadedTrackMetadata) throws -> MusicTrack {
        try context.performAndWait {
            // 直接使用当前 context 的模型，避免测试/降级容器并存时 Core Data 按全局 subclass 歧义取错 entity。
            let description = NSEntityDescription.entity(
                forEntityName: "DownloadedTrackEntity",
                in: context
            )!
            let entity = DownloadedTrackEntity(entity: description, insertInto: context)
            entity.id = metadata.id
            entity.fileName = metadata.fileName
            entity.title = metadata.title
            entity.artist = metadata.artist
            entity.album = metadata.album
            entity.duration = metadata.duration
            entity.createdAt = metadata.createdAt
            entity.lastPlayedAt = metadata.lastPlayedAt
            entity.sourceURL = metadata.sourceURL?.absoluteString

            do {
                try context.save()
                return Self.makeTrack(from: Self.record(from: entity))
            } catch {
                context.rollback()
                throw error
            }
        }
    }

    func delete(id: String) throws {
        try context.performAndWait {
            let request = DownloadedTrackEntity.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", id)
            for entity in try context.fetch(request) {
                context.delete(entity)
            }
            if context.hasChanges {
                do {
                    try context.save()
                } catch {
                    context.rollback()
                    throw error
                }
            }
        }
    }

    nonisolated private static func fetchRecords(
        in context: NSManagedObjectContext
    ) throws -> [LocalTrackRecord] {
        let request = NSFetchRequest<DownloadedTrackEntity>(entityName: "DownloadedTrackEntity")
        request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: true)]
        return try context.fetch(request).map(record)
    }

    nonisolated private static func record(from entity: DownloadedTrackEntity) -> LocalTrackRecord {
        LocalTrackRecord(
            id: entity.id,
            fileName: entity.fileName,
            title: entity.title,
            artist: entity.artist,
            album: entity.album,
            duration: entity.duration
        )
    }

    nonisolated private static func makeTrack(from record: LocalTrackRecord) -> MusicTrack {
        MusicTrack(
            id: record.id,
            title: record.title,
            artist: record.artist,
            album: record.album,
            duration: record.duration,
            artworkData: nil,
            source: .downloaded(fileName: record.fileName)
        )
    }
}

private extension DownloadedTrackEntity {
    @nonobjc class func fetchRequest() -> NSFetchRequest<DownloadedTrackEntity> {
        NSFetchRequest<DownloadedTrackEntity>(entityName: "DownloadedTrackEntity")
    }
}
