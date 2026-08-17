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

    init(
        id: String,
        fileName: String,
        title: String,
        artist: String,
        album: String,
        duration: TimeInterval,
        createdAt: Date = Date(),
        lastPlayedAt: Date? = nil
    ) {
        self.id = id
        self.fileName = fileName
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.createdAt = createdAt
        self.lastPlayedAt = lastPlayedAt
    }
}

/// Core Data 下载索引的事务边界；文件的创建和删除由 DownloadManager 负责。
final class LocalMusicStore {
    private let container: NSPersistentContainer
    private var context: NSManagedObjectContext { container.viewContext }

    init(container: NSPersistentContainer) {
        self.container = container
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
            let request = DownloadedTrackEntity.fetchRequest()
            request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: true)]
            return try context.fetch(request).map(Self.makeTrack)
        }
    }

    func insert(_ metadata: DownloadedTrackMetadata) throws -> MusicTrack {
        try context.performAndWait {
            let entity = DownloadedTrackEntity(context: context)
            entity.id = metadata.id
            entity.fileName = metadata.fileName
            entity.title = metadata.title
            entity.artist = metadata.artist
            entity.album = metadata.album
            entity.duration = metadata.duration
            entity.createdAt = metadata.createdAt
            entity.lastPlayedAt = metadata.lastPlayedAt

            do {
                try context.save()
                return Self.makeTrack(from: entity)
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

    nonisolated private static func makeTrack(from entity: DownloadedTrackEntity) -> MusicTrack {
        MusicTrack(
            id: entity.id,
            title: entity.title,
            artist: entity.artist,
            album: entity.album,
            duration: entity.duration,
            artworkData: nil,
            source: .downloaded(fileName: entity.fileName)
        )
    }
}

private extension DownloadedTrackEntity {
    @nonobjc class func fetchRequest() -> NSFetchRequest<DownloadedTrackEntity> {
        NSFetchRequest<DownloadedTrackEntity>(entityName: "DownloadedTrackEntity")
    }
}
