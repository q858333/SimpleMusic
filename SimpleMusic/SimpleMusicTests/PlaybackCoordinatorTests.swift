import Combine
import XCTest
@testable import SimpleMusic

@MainActor
final class PlaybackCoordinatorTests: XCTestCase {
    private var cancellables = Set<AnyCancellable>()

    override func tearDown() {
        cancellables.removeAll()
        super.tearDown()
    }

    /// 若跨来源切歌未先停止旧后端，两个系统播放器可能同时出声。
    func testCrossSourceNextStopsOldBackendBeforeLoadingNewBackend() throws {
        let local = SpyBackend(kind: .local)
        let system = SpyBackend(kind: .system)
        let sut = PlaybackCoordinator(localBackend: local, systemBackend: system)

        try sut.play(queue: [downloadedTrack(id: "local"), systemTrack(id: "system")], startAt: 0)
        try sut.next()

        XCTAssertEqual(local.events, [.load("local"), .play, .stop])
        XCTAssertEqual(system.events, [.load("system"), .play])
    }

    /// 若 previous 错误地只修改快照而未激活前一项，此测试应失败。
    func testPreviousLoadsThePreviousQueueItem() throws {
        let local = SpyBackend(kind: .local)
        let system = SpyBackend(kind: .system)
        let sut = PlaybackCoordinator(localBackend: local, systemBackend: system)
        let snapshots = observe(sut)

        try sut.play(queue: [downloadedTrack(id: "first"), systemTrack(id: "second")], startAt: 1)
        try sut.previous()

        XCTAssertEqual(system.events, [.load("second"), .play, .stop])
        XCTAssertEqual(local.loadedTrackIDs, ["first"])
        XCTAssertEqual(snapshots.value.track?.id, "first")
        XCTAssertEqual(snapshots.value.queueIndex, 0)
    }

    /// 若队列末尾继续索引越界或仍保持播放态，此测试应失败。
    func testNextAtQueueEndStopsPlayback() throws {
        let local = SpyBackend(kind: .local)
        let sut = PlaybackCoordinator(localBackend: local, systemBackend: SpyBackend(kind: .system))
        let snapshots = observe(sut)

        try sut.play(queue: [downloadedTrack(id: "only")], startAt: 0)
        try sut.next()

        XCTAssertEqual(local.events, [.load("only"), .play, .stop])
        XCTAssertEqual(snapshots.value.status, .idle)
        XCTAssertNil(snapshots.value.queueIndex)
        XCTAssertEqual(snapshots.value.queueCount, 1)
    }

    /// 若随机播放丢曲、重复曲目或提前结束，此测试应失败。
    func testShuffledQueueLoadsEveryTrackIDExactlyOnce() throws {
        let local = SpyBackend(kind: .local)
        let sut = PlaybackCoordinator(localBackend: local, systemBackend: SpyBackend(kind: .system))
        let tracks = (0..<12).map { downloadedTrack(id: "track-\($0)") }

        try sut.playShuffled(queue: tracks)
        for _ in 1..<tracks.count {
            try sut.next()
        }

        XCTAssertEqual(local.loadedTrackIDs.count, tracks.count)
        XCTAssertEqual(Set(local.loadedTrackIDs), Set(tracks.map(\.id)))
    }

    /// 若空队列错误触发任一后端，此测试应失败。
    func testEmptyQueueDoesNotPlay() throws {
        let local = SpyBackend(kind: .local)
        let system = SpyBackend(kind: .system)
        let sut = PlaybackCoordinator(localBackend: local, systemBackend: system)
        let snapshots = observe(sut)

        try sut.play(queue: [], startAt: 0)
        try sut.playShuffled(queue: [])

        XCTAssertTrue(local.events.isEmpty)
        XCTAssertTrue(system.events.isEmpty)
        XCTAssertEqual(snapshots.value, PlaybackSnapshot())
    }

    /// 若非法起始索引被静默修正，调用方无法发现队列状态错误。
    func testNonemptyQueueRejectsInvalidStartIndex() {
        let local = SpyBackend(kind: .local)
        let sut = PlaybackCoordinator(localBackend: local, systemBackend: SpyBackend(kind: .system))

        XCTAssertThrowsError(try sut.play(queue: [downloadedTrack(id: "only")], startAt: 1))
        XCTAssertTrue(local.events.isEmpty)
    }

    /// 若播放/暂停切换只操作后端却不发布状态，界面会显示过期状态。
    func testTogglePlayPausesAndResumesActiveBackend() throws {
        let local = SpyBackend(kind: .local)
        let sut = PlaybackCoordinator(localBackend: local, systemBackend: SpyBackend(kind: .system))
        let snapshots = observe(sut)
        try sut.play(queue: [downloadedTrack(id: "only")], startAt: 0)

        sut.togglePlay()
        XCTAssertEqual(snapshots.value.status, .paused)
        sut.togglePlay()

        XCTAssertEqual(snapshots.value.status, .playing)
        XCTAssertEqual(local.events, [.load("only"), .play, .pause, .play])
    }

    /// 若 seek 未转发或快照未同步，界面进度会在下一次周期回调前回跳。
    func testSeekUpdatesSnapshotAndActiveBackend() throws {
        let local = SpyBackend(kind: .local)
        let sut = PlaybackCoordinator(localBackend: local, systemBackend: SpyBackend(kind: .system))
        let snapshots = observe(sut)
        try sut.play(queue: [downloadedTrack(id: "only")], startAt: 0)

        sut.seek(to: 18)

        XCTAssertEqual(local.seekValues, [18])
        XCTAssertEqual(snapshots.value.elapsed, 18)
    }

    /// 若活动后端的周期回调没有写入协调器快照，播放进度不会更新。
    func testDelegateElapsedUpdatePublishesProgress() throws {
        let local = SpyBackend(kind: .local)
        let sut = PlaybackCoordinator(localBackend: local, systemBackend: SpyBackend(kind: .system))
        let snapshots = observe(sut)
        try sut.play(queue: [downloadedTrack(id: "only")], startAt: 0)

        local.reportElapsed(7, duration: 42)

        XCTAssertEqual(snapshots.value.elapsed, 7)
        XCTAssertEqual(snapshots.value.duration, 42)
    }

    /// 若完成回调没有由协调器推进索引，播放会停在已结束的曲目。
    func testDelegateFinishAdvancesToNextTrack() throws {
        let local = SpyBackend(kind: .local)
        let sut = PlaybackCoordinator(localBackend: local, systemBackend: SpyBackend(kind: .system))
        let snapshots = observe(sut)
        try sut.play(queue: [downloadedTrack(id: "first"), downloadedTrack(id: "second")], startAt: 0)

        local.reportFinished()

        XCTAssertEqual(local.loadedTrackIDs, ["first", "second"])
        XCTAssertEqual(snapshots.value.track?.id, "second")
        XCTAssertEqual(snapshots.value.queueIndex, 1)
    }

    /// 若最后一曲完成后没有停止，快照会错误地保持 playing。
    func testDelegateFinishAtQueueEndStopsPlayback() throws {
        let local = SpyBackend(kind: .local)
        let sut = PlaybackCoordinator(localBackend: local, systemBackend: SpyBackend(kind: .system))
        let snapshots = observe(sut)
        try sut.play(queue: [downloadedTrack(id: "only")], startAt: 0)

        local.reportFinished()

        XCTAssertEqual(local.stopCount, 1)
        XCTAssertEqual(snapshots.value.status, .idle)
        XCTAssertNil(snapshots.value.queueIndex)
    }

    /// 若后端错误未进入统一快照，界面和日志层无法观察播放失败。
    func testDelegateFailurePublishesFailedSnapshot() throws {
        let local = SpyBackend(kind: .local)
        let sut = PlaybackCoordinator(localBackend: local, systemBackend: SpyBackend(kind: .system))
        let snapshots = observe(sut)
        try sut.play(queue: [downloadedTrack(id: "only")], startAt: 0)

        local.reportFailure(TestError.backendFailure)

        XCTAssertEqual(snapshots.value.status, .failed("backendFailure"))
        XCTAssertEqual(snapshots.value.track?.id, "only")
    }

    /// 若切源后的旧后端迟到回调仍能覆盖快照，当前曲目的状态会被污染。
    func testStaleBackendCallbacksAreIgnoredAfterCrossSourceSwitch() throws {
        let local = SpyBackend(kind: .local)
        let system = SpyBackend(kind: .system)
        let sut = PlaybackCoordinator(localBackend: local, systemBackend: system)
        let snapshots = observe(sut)
        try sut.play(queue: [downloadedTrack(id: "local"), systemTrack(id: "system")], startAt: 0)
        try sut.next()

        local.reportElapsed(99, duration: 100)
        local.reportFailure(TestError.staleFailure)

        XCTAssertEqual(snapshots.value.track?.id, "system")
        XCTAssertEqual(snapshots.value.elapsed, 0)
        XCTAssertEqual(snapshots.value.status, .playing)
    }

    private func observe(_ coordinator: PlaybackCoordinator) -> SnapshotRecorder {
        let recorder = SnapshotRecorder()
        coordinator.snapshotPublisher
            .sink { recorder.value = $0 }
            .store(in: &cancellables)
        return recorder
    }

    private func downloadedTrack(id: String) -> MusicTrack {
        MusicTrack(
            id: id,
            title: id,
            artist: "artist",
            album: "album",
            duration: 60,
            artworkData: nil,
            source: .downloaded(fileName: "\(id).mp3")
        )
    }

    private func systemTrack(id: String) -> MusicTrack {
        MusicTrack(
            id: id,
            title: id,
            artist: "artist",
            album: "album",
            duration: 60,
            artworkData: nil,
            source: .system(persistentID: UInt64(abs(id.hashValue)))
        )
    }
}

@MainActor
private final class SnapshotRecorder {
    var value = PlaybackSnapshot()
}

@MainActor
private final class SpyBackend: PlaybackBackend {
    enum Event: Equatable {
        case load(String)
        case play
        case pause
        case stop
        case seek(TimeInterval)
    }

    let kind: PlaybackBackendKind
    weak var delegate: PlaybackBackendDelegate?
    private(set) var events = [Event]()

    var loadedTrackIDs: [String] {
        events.compactMap { event in
            guard case let .load(id) = event else { return nil }
            return id
        }
    }

    var stopCount: Int { events.filter { $0 == .stop }.count }

    var seekValues: [TimeInterval] {
        events.compactMap { event in
            guard case let .seek(seconds) = event else { return nil }
            return seconds
        }
    }

    init(kind: PlaybackBackendKind) {
        self.kind = kind
    }

    func load(_ track: MusicTrack) throws { events.append(.load(track.id)) }
    func play() { events.append(.play) }
    func pause() { events.append(.pause) }
    func stop() { events.append(.stop) }
    func seek(to seconds: TimeInterval) { events.append(.seek(seconds)) }

    func reportElapsed(_ elapsed: TimeInterval, duration: TimeInterval) {
        delegate?.playbackBackend(self, didUpdateElapsed: elapsed, duration: duration)
    }

    func reportFinished() {
        delegate?.playbackBackendDidFinish(self)
    }

    func reportFailure(_ error: Error) {
        delegate?.playbackBackend(self, didFail: error)
    }
}

private enum TestError: Error {
    case backendFailure
    case staleFailure
}
