import MediaPlayer
import XCTest
@testable import SimpleMusic

final class MusicLibraryServiceMappingTests: XCTestCase {
    /// 如果 async 系统查询仍在 MainActor 执行，阻塞 gate 会阻止测试观察 started 状态。
    @MainActor
    func testAsyncFetchRunsBlockingMetadataQueryOffMainActor() async throws {
        let gate = SystemQueryGate()
        let probe = SystemQueryThreadProbe()
        let service = MusicLibraryService(
            authorizationStatusProvider: { .authorized },
            metadataQuery: {
                probe.recordCurrentThread()
                gate.wait()
                return [SystemTrackMetadata(
                    persistentID: 88,
                    title: "后台歌曲",
                    artist: "后台艺人",
                    album: "后台专辑",
                    duration: 30,
                    artworkData: nil
                )]
            }
        )
        defer { gate.open() }

        let fetch = Task { try await service.fetchTracksAsync() }
        let queryStarted = await eventually { probe.hasRecordedThread }
        XCTAssertTrue(queryStarted)
        XCTAssertEqual(probe.wasMainThread, false)
        XCTAssertTrue(Thread.isMainThread)

        gate.open()
        let tracks = try await fetch.value
        XCTAssertEqual(tracks.map(\.id), ["system-88"])
    }

    /// 如果后台查询结束后不再读取最新权限，撤权期间取得的 metadata 会被错误返回。
    @MainActor
    func testAsyncFetchDiscardsMetadataWhenAuthorizationIsRevokedDuringQuery() async throws {
        for revokedStatus in [
            MPMediaLibraryAuthorizationStatus.denied,
            .restricted
        ] {
            let authorization = MutableSystemAuthorizationStatus(.authorized)
            let gate = SystemQueryGate()
            let probe = SystemQueryThreadProbe()
            let service = MusicLibraryService(
                authorizationStatusProvider: { authorization.value },
                metadataQuery: {
                    probe.recordCurrentThread()
                    gate.wait()
                    return [SystemTrackMetadata(
                        persistentID: 99,
                        title: "已撤权歌曲",
                        artist: "系统艺人",
                        album: "系统专辑",
                        duration: 30,
                        artworkData: nil
                    )]
                }
            )
            defer { gate.open() }

            let fetch = Task { try await service.fetchTracksAsync() }
            let queryStarted = await eventually { probe.hasRecordedThread }
            XCTAssertTrue(queryStarted)

            authorization.value = revokedStatus
            gate.open()

            let tracks = try await fetch.value
            XCTAssertTrue(tracks.isEmpty, "查询后权限为 \(revokedStatus.rawValue) 时必须丢弃 metadata")
        }
    }

    /// 如果映射不再为缺失元数据提供可展示的默认值，此测试应失败。
    @MainActor
    func testMissingMetadataUsesSystemIdentifierAndUnknownCopy() {
        let track = MusicLibraryService.makeTrack(from: .init(
            persistentID: 42,
            title: nil,
            artist: nil,
            album: nil,
            duration: 8,
            artworkData: nil
        ))

        XCTAssertEqual(track.id, "system-42")
        XCTAssertEqual(track.title, "system-42")
        XCTAssertEqual(track.artist, MusicTrack.unknownArtist)
        XCTAssertEqual(track.album, MusicTrack.unknownAlbum)
        XCTAssertEqual(track.duration, 8)
        XCTAssertEqual(track.source, .system(persistentID: 42))
    }

    /// 如果系统音乐已有元数据却被默认文案覆盖，此测试应失败。
    @MainActor
    func testMetadataKeepsSystemMusicValues() {
        let track = MusicLibraryService.makeTrack(from: .init(
            persistentID: 7,
            title: "系统歌曲",
            artist: "系统艺人",
            album: "系统专辑",
            duration: 61,
            artworkData: Data([0x01])
        ))

        XCTAssertEqual(track.id, "system-7")
        XCTAssertEqual(track.title, "系统歌曲")
        XCTAssertEqual(track.artist, "系统艺人")
        XCTAssertEqual(track.album, "系统专辑")
        XCTAssertEqual(track.duration, 61)
        XCTAssertEqual(track.artworkData, Data([0x01]))
        XCTAssertEqual(track.source, .system(persistentID: 7))
    }

    @MainActor
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

private final class SystemQueryGate: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)

    func wait() {
        _ = semaphore.wait(timeout: .now() + 1)
    }

    func open() {
        semaphore.signal()
    }
}

private final class SystemQueryThreadProbe: @unchecked Sendable {
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

private final class MutableSystemAuthorizationStatus: @unchecked Sendable {
    private let lock = NSLock()
    private var status: MPMediaLibraryAuthorizationStatus

    init(_ status: MPMediaLibraryAuthorizationStatus) {
        self.status = status
    }

    var value: MPMediaLibraryAuthorizationStatus {
        get { lock.withLock { status } }
        set { lock.withLock { status = newValue } }
    }
}
