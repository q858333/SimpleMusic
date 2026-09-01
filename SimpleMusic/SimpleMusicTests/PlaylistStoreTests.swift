import CoreData
import XCTest
@testable import SimpleMusic

@MainActor
final class PlaylistStoreTests: XCTestCase {
    /// 若空白名称能落盘，列表页会出现无法辨识的播放列表。
    func testCreateRejectsBlankName() throws {
        let store = try PlaylistStore.inMemory()

        XCTAssertThrowsError(try store.create(name: "   "))
        XCTAssertTrue(try store.fetchPlaylists().isEmpty)
    }

    /// 若没有名称唯一性检查，用户会得到两个无法区分的同名播放列表。
    func testCreateRejectsDuplicateName() throws {
        let store = try PlaylistStore.inMemory()
        _ = try store.create(name: "晨间")

        XCTAssertThrowsError(try store.create(name: "晨间"))
        XCTAssertEqual(try store.fetchPlaylists().map(\.name), ["晨间"])
    }

    /// 若创建没有保存快照，重新查询将得不到稳定的 ID 和初始空歌曲列表。
    func testCreateFetchesPlaylistWithInitialMetadata() throws {
        let store = try PlaylistStore.inMemory()

        let playlist = try store.create(name: "晨间")

        let fetched = try XCTUnwrap(store.fetchPlaylists().first)
        XCTAssertEqual(fetched.id, playlist.id)
        XCTAssertEqual(fetched.name, "晨间")
        XCTAssertEqual(fetched.trackIDs, [])
        XCTAssertLessThanOrEqual(fetched.createdAt, fetched.updatedAt)
    }

    /// 若重命名没有更新目标行，后续列表读取仍会显示旧名称。
    func testRenameUpdatesOnlyRequestedPlaylist() throws {
        let store = try PlaylistStore.inMemory()
        let morning = try store.create(name: "晨间")
        _ = try store.create(name: "夜晚")

        try store.rename(id: morning.id, name: "通勤")

        XCTAssertEqual(try store.fetchPlaylists().map(\.name), ["通勤", "夜晚"])
    }

    /// 删除播放列表只能删除列表项，不能删除已有下载歌曲索引。
    func testDeleteRemovesPlaylistWithoutDeletingDownloadedTrack() throws {
        let container = try makeInMemoryContainer()
        let playlistStore = PlaylistStore(container: container)
        let musicStore = LocalMusicStore(container: container)
        _ = try musicStore.insert(DownloadedTrackMetadata(
            id: "track-1",
            fileName: "track-1.m4a",
            title: "Track 1",
            artist: "Artist",
            album: "Album",
            duration: 10
        ))
        let playlist = try playlistStore.create(name: "晨间")
        try playlistStore.add(trackID: "track-1", to: playlist.id)

        try playlistStore.delete(id: playlist.id)

        XCTAssertTrue(try playlistStore.fetchPlaylists().isEmpty)
        XCTAssertEqual(try musicStore.fetchTracks().map(\.id), ["track-1"])
    }

    /// 若 position 未按追加顺序读取，播放列表的播放顺序会改变。
    func testAddAppendsTrackIDsInOrder() throws {
        let store = try PlaylistStore.inMemory()
        let playlist = try store.create(name: "晨间")

        try store.add(trackID: "track-2", to: playlist.id)
        try store.add(trackID: "track-1", to: playlist.id)

        XCTAssertEqual(try store.tracks(in: playlist.id), ["track-2", "track-1"])
    }

    /// 若重复歌曲没有去重，同一首歌会在播放队列中出现两次。
    func testAddingSameTrackTwiceKeepsOneOrderedItem() throws {
        let store = try PlaylistStore.inMemory()
        let playlist = try store.create(name: "晨间")
        try store.add(trackID: "track-1", to: playlist.id)

        try store.add(trackID: "track-1", to: playlist.id)

        XCTAssertEqual(try store.tracks(in: playlist.id), ["track-1"])
    }

    /// 资料库中已不存在的歌曲 ID 必须从所有受影响播放列表移除。
    func testRemoveMissingTrackIDsRemovesOnlyMissingItems() throws {
        let store = try PlaylistStore.inMemory()
        let morning = try store.create(name: "晨间")
        let evening = try store.create(name: "夜晚")
        try store.add(trackID: "keep", to: morning.id)
        try store.add(trackID: "missing", to: morning.id)
        try store.add(trackID: "missing", to: evening.id)

        try store.removeMissingTrackIDs(["missing"])

        XCTAssertEqual(try store.tracks(in: morning.id), ["keep"])
        XCTAssertEqual(try store.tracks(in: evening.id), [])
    }

    /// 若 V2 不能轻量迁移到 V3，已下载歌曲索引会在添加播放列表功能后丢失或加载失败。
    func testLightweightMigrationFromV2KeepsDownloadedTrack() throws {
        let modelBundle = Bundle(for: DownloadedTrackEntity.self)
        let modelDirectory = try XCTUnwrap(
            modelBundle.url(forResource: "SimpleMusic", withExtension: "momd")
        )
        let v2ModelURL = modelDirectory.appendingPathComponent("SimpleMusicV2.mom")
        let v2Model = try XCTUnwrap(NSManagedObjectModel(contentsOf: v2ModelURL))

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlaylistMigrationTests-\(UUID().uuidString)", isDirectory: true)
        let storeURL = directory.appendingPathComponent("SimpleMusic.sqlite")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let legacyContainer = NSPersistentContainer(name: "SimpleMusic", managedObjectModel: v2Model)
        let legacyDescription = NSPersistentStoreDescription(url: storeURL)
        legacyDescription.shouldAddStoreAsynchronously = false
        legacyContainer.persistentStoreDescriptions = [legacyDescription]
        try loadPersistentStores(in: legacyContainer)

        let legacyEntity = NSEntityDescription.insertNewObject(
            forEntityName: "DownloadedTrackEntity",
            into: legacyContainer.viewContext
        )
        legacyEntity.setValue("legacy", forKey: "id")
        legacyEntity.setValue("legacy.m4a", forKey: "fileName")
        legacyEntity.setValue("Legacy", forKey: "title")
        legacyEntity.setValue("Artist", forKey: "artist")
        legacyEntity.setValue("Album", forKey: "album")
        legacyEntity.setValue(12.0, forKey: "duration")
        legacyEntity.setValue(Date(timeIntervalSince1970: 1), forKey: "createdAt")
        try legacyContainer.viewContext.save()
        try legacyContainer.persistentStoreCoordinator.remove(
            try XCTUnwrap(legacyContainer.persistentStoreCoordinator.persistentStores.first)
        )

        let migratedContainer = NSPersistentContainer(name: "SimpleMusic")
        let migratedDescription = NSPersistentStoreDescription(url: storeURL)
        migratedDescription.shouldAddStoreAsynchronously = false
        migratedDescription.shouldMigrateStoreAutomatically = true
        migratedDescription.shouldInferMappingModelAutomatically = true
        migratedContainer.persistentStoreDescriptions = [migratedDescription]
        try loadPersistentStores(in: migratedContainer)

        let request = NSFetchRequest<NSManagedObject>(entityName: "DownloadedTrackEntity")
        let migratedEntity = try XCTUnwrap(migratedContainer.viewContext.fetch(request).first)
        XCTAssertEqual(migratedEntity.value(forKey: "id") as? String, "legacy")
        XCTAssertEqual(migratedEntity.value(forKey: "sourceURL") as? String, nil)
    }

    private func makeInMemoryContainer() throws -> NSPersistentContainer {
        let container = NSPersistentContainer(name: "SimpleMusic")
        let description = NSPersistentStoreDescription()
        description.type = NSInMemoryStoreType
        description.shouldAddStoreAsynchronously = false
        container.persistentStoreDescriptions = [description]
        try loadPersistentStores(in: container)
        return container
    }

    private func loadPersistentStores(in container: NSPersistentContainer) throws {
        var loadingError: Error?
        container.loadPersistentStores { _, error in loadingError = error }
        if let loadingError { throw loadingError }
    }
}
