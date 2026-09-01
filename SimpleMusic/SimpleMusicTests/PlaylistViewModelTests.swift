import MediaPlayer
import XCTest
@testable import SimpleMusic

@MainActor
final class PlaylistViewModelTests: XCTestCase {
    /// 若列表页缓存歌曲快照，资料库更新后仍会展示已不存在的歌曲。
    func testPlaylistTracksResolveAgainstLatestLibraryTracks() async throws {
        let track = makeTrack(id: "a")
        let source = MutableMusicLibrary(tracks: [track])
        let library = makeLibraryViewModel(source: source)
        await library.reload()
        let store = try PlaylistStore.inMemory()
        let sut = try PlaylistViewModel(store: store, library: library)
        let playlist = try sut.createPlaylist(named: "收藏")
        try sut.add(track, to: playlist.id)

        XCTAssertEqual(sut.tracks(for: playlist.id), [track])

        source.tracks = []
        await library.reload()

        XCTAssertTrue(sut.tracks(for: playlist.id).isEmpty)
    }

    /// 若资料库发布后不清理失效 ID，已删除歌曲会永久留在持久化播放列表中。
    func testLibraryRefreshRemovesMissingTrackIDsFromPlaylistItems() async throws {
        let keep = makeTrack(id: "keep")
        let missing = makeTrack(id: "missing")
        let source = MutableMusicLibrary(tracks: [keep, missing])
        let library = makeLibraryViewModel(source: source)
        await library.reload()
        let store = try PlaylistStore.inMemory()
        let sut = try PlaylistViewModel(store: store, library: library)
        let playlist = try sut.createPlaylist(named: "通勤")
        try sut.add(keep, to: playlist.id)
        try sut.add(missing, to: playlist.id)

        source.tracks = [keep]
        await library.reload()

        XCTAssertEqual(try store.tracks(in: playlist.id), ["keep"])
        XCTAssertEqual(sut.tracks(for: playlist.id), [keep])
        XCTAssertEqual(library.tracks, [keep])
    }

    /// 系统来源先发布空结果时，尚在读取的本地歌曲不能被当成永久缺失而清理。
    func testDelayedLocalSourceKeepsPlaylistItemThroughSystemIntermediatePublish() async throws {
        let localTrack = makeTrack(id: "local")
        let localStore = DeferredLocalMusicStore()
        let library = LibraryViewModel(
            library: MutableMusicLibrary(tracks: []),
            localStore: localStore
        )
        let store = try PlaylistStore.inMemory()
        let playlist = try store.create(name: "本地")
        try store.add(trackID: localTrack.id, to: playlist.id)
        let sut = try PlaylistViewModel(store: store, library: library)

        let reload = Task { await library.reload() }
        let didPublishSystemResult = await eventually {
            library.systemState == .empty && library.localState == .loading && library.tracks.isEmpty
        }
        XCTAssertTrue(didPublishSystemResult)
        XCTAssertEqual(try store.tracks(in: playlist.id), [localTrack.id])
        XCTAssertTrue(sut.tracks(for: playlist.id).isEmpty)

        localStore.resumeRequestIfPending(with: [localTrack])
        await reload.value

        XCTAssertEqual(try store.tracks(in: playlist.id), [localTrack.id])
        XCTAssertEqual(sut.tracks(for: playlist.id), [localTrack])
    }

    /// 本地来源先发布空结果时，尚在读取的系统歌曲不能被当成永久缺失而清理。
    func testDelayedSystemSourceKeepsPlaylistItemThroughLocalIntermediatePublish() async throws {
        let systemTrack = makeTrack(id: "system")
        let systemLibrary = DeferredMusicLibrary()
        let library = LibraryViewModel(
            library: systemLibrary,
            localStore: EmptyLocalMusicStore()
        )
        let store = try PlaylistStore.inMemory()
        let playlist = try store.create(name: "系统")
        try store.add(trackID: systemTrack.id, to: playlist.id)
        let sut = try PlaylistViewModel(store: store, library: library)

        let reload = Task { await library.reload() }
        let didPublishLocalResult = await eventually {
            library.systemState == .loading && library.localState == .empty && library.tracks.isEmpty
        }
        XCTAssertTrue(didPublishLocalResult)
        XCTAssertEqual(try store.tracks(in: playlist.id), [systemTrack.id])
        XCTAssertTrue(sut.tracks(for: playlist.id).isEmpty)

        systemLibrary.resumeRequestIfPending(with: [systemTrack])
        await reload.value

        XCTAssertEqual(try store.tracks(in: playlist.id), [systemTrack.id])
        XCTAssertEqual(sut.tracks(for: playlist.id), [systemTrack])
    }

    private func makeLibraryViewModel(source: MutableMusicLibrary) -> LibraryViewModel {
        LibraryViewModel(library: source, localStore: EmptyLocalMusicStore())
    }

    private func makeTrack(id: String) -> SimpleMusic.MusicTrack {
        SimpleMusic.MusicTrack(
            id: id,
            title: "歌曲 \(id)",
            artist: "艺人",
            album: "专辑",
            duration: 180,
            artworkData: nil,
            source: .system(persistentID: 1)
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

@MainActor
private final class MutableMusicLibrary: MusicLibraryLoading {
    var tracks: [SimpleMusic.MusicTrack]
    let authorizationStatus: MPMediaLibraryAuthorizationStatus = .authorized

    init(tracks: [SimpleMusic.MusicTrack]) {
        self.tracks = tracks
    }

    func loadTracks() async throws -> [SimpleMusic.MusicTrack] {
        tracks
    }
}

private final class EmptyLocalMusicStore: LocalMusicLoading {
    func loadTracks() async throws -> [SimpleMusic.MusicTrack] {
        []
    }
}

@MainActor
private final class DeferredMusicLibrary: MusicLibraryLoading {
    let authorizationStatus: MPMediaLibraryAuthorizationStatus = .authorized
    private var continuations = [CheckedContinuation<[SimpleMusic.MusicTrack], Never>]()

    func loadTracks() async throws -> [SimpleMusic.MusicTrack] {
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func resumeRequestIfPending(with tracks: [SimpleMusic.MusicTrack]) {
        guard continuations.isEmpty == false else { return }
        continuations.removeFirst().resume(returning: tracks)
    }
}

@MainActor
private final class DeferredLocalMusicStore: LocalMusicLoading {
    private var continuations = [CheckedContinuation<[SimpleMusic.MusicTrack], Never>]()

    func loadTracks() async throws -> [SimpleMusic.MusicTrack] {
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func resumeRequestIfPending(with tracks: [SimpleMusic.MusicTrack]) {
        guard continuations.isEmpty == false else { return }
        continuations.removeFirst().resume(returning: tracks)
    }
}
