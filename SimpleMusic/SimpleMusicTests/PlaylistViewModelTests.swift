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
