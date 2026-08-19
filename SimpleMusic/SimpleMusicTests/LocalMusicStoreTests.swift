import CoreData
import XCTest
@testable import SimpleMusic

@MainActor
final class LocalMusicStoreTests: XCTestCase {
    /// 如果 async fetch 仍使用 viewContext.performAndWait，阻塞查询会占住 MainActor。
    func testAsyncFetchRunsBlockingQueryOnBackgroundContext() async throws {
        let gate = LocalQueryGate()
        let probe = LocalQueryThreadProbe()
        let store = LocalMusicStore(
            container: try makeInMemoryContainer(),
            backgroundQuery: { _ in
                probe.recordCurrentThread()
                gate.wait()
                return [LocalTrackRecord(
                    id: "background",
                    fileName: "background.m4a",
                    title: "后台歌曲",
                    artist: "后台艺人",
                    album: "后台专辑",
                    duration: 42
                )]
            }
        )
        defer { gate.open() }

        let fetch = Task { try await store.fetchTracksAsync() }
        let queryStarted = await eventually { probe.hasRecordedThread }
        XCTAssertTrue(queryStarted)
        XCTAssertEqual(probe.wasMainThread, false)
        XCTAssertTrue(Thread.isMainThread)

        gate.open()
        let tracks = try await fetch.value
        XCTAssertEqual(tracks.map(\MusicTrack.id), ["background"])
        XCTAssertEqual(tracks.first?.source, .downloaded(fileName: "background.m4a"))
    }

    func testInsertFetchAndDeleteDownloadedTrack() throws {
        let store = try LocalMusicStore.inMemory()
        let metadata = DownloadedTrackMetadata(
            id: "one",
            fileName: "one.mp3",
            title: "One",
            artist: "A",
            album: "B",
            duration: 12
        )

        let inserted = try store.insert(metadata)

        XCTAssertEqual(inserted.id, "one")
        XCTAssertEqual(inserted.title, "One")
        XCTAssertEqual(inserted.artist, "A")
        XCTAssertEqual(inserted.album, "B")
        XCTAssertEqual(inserted.duration, 12)
        XCTAssertEqual(inserted.source, .downloaded(fileName: "one.mp3"))
        XCTAssertEqual(try store.fetchTracks().map(\.id), ["one"])

        try store.delete(id: "one")

        XCTAssertTrue(try store.fetchTracks().isEmpty)
    }

    func testCatalogKeepsPlayableRecordAndFile() async throws {
        let fixture = try makeCatalogFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let track = try fixture.musicStore.insert(metadata(id: "good", fileName: "good.mp3"))
        try Data("valid".utf8).write(to: fixture.root.appendingPathComponent("good.mp3"))

        let tracks = try await fixture.catalog.loadTracks()

        XCTAssertEqual(tracks, [track])
        XCTAssertEqual(try fixture.musicStore.fetchTracks().map(\.id), ["good"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("good.mp3").path))
    }

    func testCatalogExcludesMissingRecordAndDeletesItsIndex() async throws {
        let fixture = try makeCatalogFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try fixture.musicStore.insert(metadata(id: "missing", fileName: "missing.mp3"))

        let tracks = try await fixture.catalog.loadTracks()
        XCTAssertTrue(tracks.isEmpty)
        XCTAssertTrue(try fixture.musicStore.fetchTracks().isEmpty)
    }

    func testCatalogKeepsIndexWhenLeaseCreationFailsTransiently() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileStore = try DownloadFileStore(rootURL: root)
        let musicStore = try LocalMusicStore.inMemory()
        let track = try musicStore.insert(metadata(id: "transient", fileName: "transient.mp3"))
        try Data("valid".utf8).write(to: root.appendingPathComponent("transient.mp3"))
        let catalog = LocalMusicCatalog(
            musicStore: musicStore,
            fileStore: fileStore,
            leaseProvider: { _ in throw DownloadFileStoreError.playbackLeaseCreationFailed },
            playabilityCheck: { _ in true }
        )

        await XCTAssertThrowsErrorAsync(_ = try await catalog.loadTracks())

        XCTAssertEqual(try musicStore.fetchTracks().map(\.id), [track.id])
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: root.appendingPathComponent("transient.mp3").path)
        )
    }

    func testCatalogExcludesDamagedRecordAndDeletesItsIndex() async throws {
        let fixture = try makeCatalogFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try fixture.musicStore.insert(metadata(id: "broken", fileName: "broken.mp3"))
        try Data("damaged".utf8).write(to: fixture.root.appendingPathComponent("broken.mp3"))

        let tracks = try await fixture.catalog.loadTracks()
        XCTAssertTrue(tracks.isEmpty)
        XCTAssertTrue(try fixture.musicStore.fetchTracks().isEmpty)
    }

    func testCatalogRejectsSymlinkWithoutDeletingOutsideTarget() async throws {
        let fixture = try makeCatalogFixture()
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: fixture.root)
            try? FileManager.default.removeItem(at: outside)
        }
        try Data("outside".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: fixture.root.appendingPathComponent("linked.mp3"),
            withDestinationURL: outside
        )
        _ = try fixture.musicStore.insert(metadata(id: "linked", fileName: "linked.mp3"))

        let tracks = try await fixture.catalog.loadTracks()
        XCTAssertTrue(tracks.isEmpty)
        XCTAssertTrue(try fixture.musicStore.fetchTracks().isEmpty)
        XCTAssertEqual(try Data(contentsOf: outside), Data("outside".utf8))
    }

    func testCatalogDeletesDownloadedFileAndRecord() async throws {
        let fixture = try makeCatalogFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let track = try fixture.musicStore.insert(metadata(id: "delete", fileName: "delete.mp3"))
        let fileURL = fixture.root.appendingPathComponent("delete.mp3")
        try Data("valid".utf8).write(to: fileURL)

        try await fixture.catalog.delete(track)

        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertTrue(try fixture.musicStore.fetchTracks().isEmpty)
    }

    func testCatalogDeleteUnlinksSymlinkWithoutTouchingOutsideTarget() async throws {
        let fixture = try makeCatalogFixture()
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: fixture.root)
            try? FileManager.default.removeItem(at: outside)
        }
        try Data("outside".utf8).write(to: outside)
        let linkURL = fixture.root.appendingPathComponent("linked.mp3")
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: outside)
        let track = try fixture.musicStore.insert(metadata(id: "linked-delete", fileName: "linked.mp3"))

        try await fixture.catalog.delete(track)

        XCTAssertFalse(FileManager.default.fileExists(atPath: linkURL.path))
        XCTAssertEqual(try Data(contentsOf: outside), Data("outside".utf8))
        XCTAssertTrue(try fixture.musicStore.fetchTracks().isEmpty)
    }

    func testCatalogDeleteRejectsTraversalAndKeepsOutsideFileAndIndex() async throws {
        let fixture = try makeCatalogFixture()
        let outside = fixture.root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: fixture.root)
            try? FileManager.default.removeItem(at: outside)
        }
        try Data("outside".utf8).write(to: outside)
        let track = try fixture.musicStore.insert(
            metadata(id: "traversal", fileName: "../\(outside.lastPathComponent)")
        )

        await XCTAssertThrowsErrorAsync(try await fixture.catalog.delete(track))

        XCTAssertEqual(try Data(contentsOf: outside), Data("outside".utf8))
        XCTAssertEqual(try fixture.musicStore.fetchTracks().map(\.id), [track.id])
    }

    func testCatalogNeverDeletesSystemTrackAsLocalFile() async throws {
        let fixture = try makeCatalogFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let systemTrack = MusicTrack(
            id: "system",
            title: "System",
            artist: "Artist",
            album: "Album",
            duration: 10,
            artworkData: nil,
            source: .system(persistentID: 42)
        )

        await XCTAssertThrowsErrorAsync(try await fixture.catalog.delete(systemTrack))
    }

    private func makeInMemoryContainer() throws -> NSPersistentContainer {
        let container = NSPersistentContainer(name: "SimpleMusic")
        let description = NSPersistentStoreDescription()
        description.type = NSInMemoryStoreType
        description.shouldAddStoreAsynchronously = false
        container.persistentStoreDescriptions = [description]

        var loadingError: Error?
        container.loadPersistentStores { _, error in loadingError = error }
        if let loadingError { throw loadingError }
        return container
    }

    private func makeCatalogFixture() throws -> (
        root: URL,
        musicStore: LocalMusicStore,
        catalog: LocalMusicCatalog
    ) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fileStore = try DownloadFileStore(rootURL: root)
        let musicStore = try LocalMusicStore.inMemory()
        let catalog = LocalMusicCatalog(
            musicStore: musicStore,
            fileStore: fileStore,
            playabilityCheck: { url in
                (try? Data(contentsOf: url)) == Data("valid".utf8)
            }
        )
        return (root, musicStore, catalog)
    }

    private func metadata(id: String, fileName: String) -> DownloadedTrackMetadata {
        DownloadedTrackMetadata(
            id: id,
            fileName: fileName,
            title: id,
            artist: "Artist",
            album: "Album",
            duration: 10
        )
    }

    private func eventually(
        attempts: Int = 100,
        condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        for _ in 0..<attempts {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: @autoclosure () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch {}
}

private final class LocalQueryGate: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)

    func wait() {
        _ = semaphore.wait(timeout: .now() + 1)
    }

    func open() {
        semaphore.signal()
    }
}

private final class LocalQueryThreadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedMainThread: Bool?

    var hasRecordedThread: Bool {
        lock.withLock { recordedMainThread != nil }
    }

    var wasMainThread: Bool? {
        lock.withLock { recordedMainThread }
    }

    func recordCurrentThread() {
        lock.withLock { recordedMainThread = Thread.isMainThread }
    }
}
