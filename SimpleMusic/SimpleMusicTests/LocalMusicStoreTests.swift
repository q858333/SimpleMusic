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
