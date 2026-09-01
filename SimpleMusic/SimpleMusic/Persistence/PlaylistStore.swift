import CoreData

struct Playlist: Equatable {
    let id: String
    let name: String
    let createdAt: Date
    let updatedAt: Date
    let trackIDs: [String]
}

enum PlaylistStoreError: Error, Equatable {
    case invalidName
    case duplicateName
    case playlistNotFound
    case modelMissingEntity
}

/// 播放列表及其歌曲 ID 的 Core Data 事务边界；歌曲元数据和文件仍由现有资料库维护。
final class PlaylistStore: @unchecked Sendable {
    private let container: NSPersistentContainer
    private var context: NSManagedObjectContext { container.viewContext }

    init(container: NSPersistentContainer) {
        self.container = container
    }

    static func inMemory() throws -> PlaylistStore {
        let container = NSPersistentContainer(name: "SimpleMusic")
        let description = NSPersistentStoreDescription()
        description.type = NSInMemoryStoreType
        description.shouldAddStoreAsynchronously = false
        container.persistentStoreDescriptions = [description]

        var loadingError: Error?
        container.loadPersistentStores { _, error in loadingError = error }
        if let loadingError { throw loadingError }
        return PlaylistStore(container: container)
    }

    func fetchPlaylists() throws -> [Playlist] {
        try context.performAndWait {
            let request = NSFetchRequest<PlaylistEntity>(entityName: "PlaylistEntity")
            request.sortDescriptors = [
                NSSortDescriptor(key: "createdAt", ascending: true),
                NSSortDescriptor(key: "id", ascending: true)
            ]
            return try context.fetch(request).map(Self.playlist)
        }
    }

    func create(name: String) throws -> Playlist {
        let name = try Self.normalizedName(name)
        return try context.performAndWait {
            try Self.ensureNameIsAvailable(name, excludingID: nil, in: context)
            let entity = PlaylistEntity(
                entity: try Self.entityDescription(named: "PlaylistEntity", in: context),
                insertInto: context
            )
            let now = Date()
            entity.id = UUID().uuidString
            entity.name = name
            entity.createdAt = now
            entity.updatedAt = now

            try Self.save(context)
            return Self.playlist(from: entity)
        }
    }

    func rename(id: String, name: String) throws {
        let name = try Self.normalizedName(name)
        try context.performAndWait {
            let entity = try Self.playlistEntity(id: id, in: context)
            try Self.ensureNameIsAvailable(name, excludingID: id, in: context)
            entity.name = name
            entity.updatedAt = Date()
            try Self.save(context)
        }
    }

    func delete(id: String) throws {
        try context.performAndWait {
            let entity = try Self.playlistEntity(id: id, in: context)
            context.delete(entity)
            try Self.save(context)
        }
    }

    func add(trackID: String, to playlistID: String) throws {
        try context.performAndWait {
            let playlist = try Self.playlistEntity(id: playlistID, in: context)
            let existingRequest = NSFetchRequest<PlaylistItemEntity>(entityName: "PlaylistItemEntity")
            existingRequest.predicate = NSPredicate(format: "playlist.id == %@", playlistID)
            let existingItems = try context.fetch(existingRequest)
            guard existingItems.contains(where: { $0.trackID == trackID }) == false else { return }
            let lastPosition = existingItems.map(\.position).max() ?? -1

            let item = PlaylistItemEntity(
                entity: try Self.entityDescription(named: "PlaylistItemEntity", in: context),
                insertInto: context
            )
            item.id = UUID().uuidString
            item.trackID = trackID
            item.addedAt = Date()
            item.position = lastPosition + 1
            item.playlist = playlist
            playlist.updatedAt = Date()
            try Self.save(context)
        }
    }

    func tracks(in playlistID: String) throws -> [String] {
        try context.performAndWait {
            _ = try Self.playlistEntity(id: playlistID, in: context)
            let request = NSFetchRequest<PlaylistItemEntity>(entityName: "PlaylistItemEntity")
            request.predicate = NSPredicate(format: "playlist.id == %@", playlistID)
            request.sortDescriptors = [
                NSSortDescriptor(key: "position", ascending: true),
                NSSortDescriptor(key: "addedAt", ascending: true),
                NSSortDescriptor(key: "id", ascending: true)
            ]
            return try context.fetch(request).map(\.trackID)
        }
    }

    func removeMissingTrackIDs(_ trackIDs: [String]) throws {
        guard trackIDs.isEmpty == false else { return }
        try context.performAndWait {
            let request = NSFetchRequest<PlaylistItemEntity>(entityName: "PlaylistItemEntity")
            request.predicate = NSPredicate(format: "trackID IN %@", trackIDs)
            for item in try context.fetch(request) {
                item.playlist?.updatedAt = Date()
                context.delete(item)
            }
            if context.hasChanges {
                try Self.save(context)
            }
        }
    }

    private static func normalizedName(_ name: String) throws -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.isEmpty == false else { throw PlaylistStoreError.invalidName }
        return name
    }

    private static func playlistEntity(id: String, in context: NSManagedObjectContext) throws -> PlaylistEntity {
        let request = NSFetchRequest<PlaylistEntity>(entityName: "PlaylistEntity")
        request.predicate = NSPredicate(format: "id == %@", id)
        request.fetchLimit = 1
        guard let entity = try context.fetch(request).first else {
            throw PlaylistStoreError.playlistNotFound
        }
        return entity
    }

    private static func ensureNameIsAvailable(
        _ name: String,
        excludingID: String?,
        in context: NSManagedObjectContext
    ) throws {
        let request = NSFetchRequest<PlaylistEntity>(entityName: "PlaylistEntity")
        if let excludingID {
            request.predicate = NSPredicate(format: "name == %@ AND id != %@", name, excludingID)
        } else {
            request.predicate = NSPredicate(format: "name == %@", name)
        }
        request.fetchLimit = 1
        guard try context.fetch(request).isEmpty else { throw PlaylistStoreError.duplicateName }
    }

    private static func entityDescription(
        named name: String,
        in context: NSManagedObjectContext
    ) throws -> NSEntityDescription {
        guard let description = NSEntityDescription.entity(forEntityName: name, in: context) else {
            throw PlaylistStoreError.modelMissingEntity
        }
        return description
    }

    private static func save(_ context: NSManagedObjectContext) throws {
        do {
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }

    nonisolated private static func playlist(from entity: PlaylistEntity) -> Playlist {
        let items = (entity.items ?? []).sorted {
            if $0.position != $1.position { return $0.position < $1.position }
            if $0.addedAt != $1.addedAt { return $0.addedAt < $1.addedAt }
            return $0.id < $1.id
        }
        return Playlist(
            id: entity.id,
            name: entity.name,
            createdAt: entity.createdAt,
            updatedAt: entity.updatedAt,
            trackIDs: items.map(\.trackID)
        )
    }
}

@objc(PlaylistEntity)
final class PlaylistEntity: NSManagedObject {
    @NSManaged var id: String
    @NSManaged var name: String
    @NSManaged var createdAt: Date
    @NSManaged var updatedAt: Date
    @NSManaged var items: Set<PlaylistItemEntity>?
}

@objc(PlaylistItemEntity)
final class PlaylistItemEntity: NSManagedObject {
    @NSManaged var id: String
    @NSManaged var trackID: String
    @NSManaged var addedAt: Date
    @NSManaged var position: Int64
    @NSManaged var playlist: PlaylistEntity?
}
