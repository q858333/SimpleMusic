import Combine
import MediaPlayer
import UIKit
import XCTest
@testable import SimpleMusic

@MainActor
final class NowPlayingServiceTests: XCTestCase {
    /// 若任一系统命令接错协调器入口，耳机或控制中心会执行错误操作。
    func testCommandsRouteOnceToTheirMatchingPlaybackControls() throws {
        let harness = makeHarness(initial: snapshot(status: .paused))

        try harness.sut.start()
        try harness.sut.start()

        XCTAssertEqual(harness.commands.addedCommands, Set(RemotePlaybackCommand.allCases))
        XCTAssertEqual(harness.commands.addCount, RemotePlaybackCommand.allCases.count)
        XCTAssertEqual(harness.commands.invoke(.play), .success)
        harness.snapshots.send(snapshot(status: .playing))
        XCTAssertEqual(harness.commands.invoke(.pause), .success)
        XCTAssertEqual(harness.commands.invoke(.next), .success)
        XCTAssertEqual(harness.commands.invoke(.previous), .success)
        XCTAssertEqual(
            harness.commands.invoke(.changePlaybackPosition, payload: .position(37)),
            .success
        )

        XCTAssertEqual(harness.controls.events, [
            .play,
            .pause,
            .next,
            .previous,
            .seek(37)
        ])
    }

    /// 后台系统回调不能等待被测试占用的主线程；动作应在主线程恢复后只执行一次。
    func testOffMainCommandReturnsBeforeMainActorDrainsThenExecutesOnce() async throws {
        let harness = makeHarness(initial: snapshot(status: .paused))
        let returned = expectation(description: "后台 handler 已返回")
        let action = expectation(description: "MainActor 执行控制动作")
        let returnedStatus = LockedValue<MPRemoteCommandHandlerStatus?>(nil)
        harness.controls.onEvent = { _ in action.fulfill() }
        try harness.sut.start()
        let commands = harness.commands

        DispatchQueue.global().async {
            returnedStatus.withLock { value in
                value = commands.invoke(.play)
            }
            returned.fulfill()
        }

        XCTAssertEqual(XCTWaiter.wait(for: [returned], timeout: 1), .completed)
        XCTAssertTrue(harness.controls.events.isEmpty)
        await fulfillment(of: [action], timeout: 1)
        XCTAssertEqual(returnedStatus.value, .success)
        XCTAssertEqual(harness.controls.events, [.play])
    }

    /// stop 后即使队列中已有 MainActor 动作，也不能再触发协调器控制。
    func testQueuedOffMainCommandDoesNotExecuteAfterStop() async throws {
        let harness = makeHarness(initial: snapshot(status: .paused))
        let returned = expectation(description: "后台 handler 已返回")
        let action = expectation(description: "stop 后不应执行")
        action.isInverted = true
        harness.controls.onEvent = { _ in action.fulfill() }
        try harness.sut.start()
        let commands = harness.commands

        DispatchQueue.global().async {
            _ = commands.invoke(.play)
            returned.fulfill()
        }

        XCTAssertEqual(XCTWaiter.wait(for: [returned], timeout: 1), .completed)
        harness.sut.stop()
        await fulfillment(of: [action], timeout: 0.2)
        XCTAssertTrue(harness.controls.events.isEmpty)
    }

    /// 若协调器切歌失败仍回报成功，系统会误以为远程命令已执行。
    func testThrowingPlaybackControlReturnsCommandFailed() throws {
        let harness = makeHarness(initial: snapshot(status: .playing))
        harness.controls.error = TestError.controlFailed
        try harness.sut.start()

        XCTAssertEqual(harness.commands.invoke(.next), .commandFailed)
        XCTAssertEqual(harness.commands.invoke(.previous), .commandFailed)
    }

    /// 无曲目或错误的拖动事件不能被报告为已成功处理。
    func testUnavailableCommandsReturnSuitableStatuses() throws {
        let harness = makeHarness(initial: PlaybackSnapshot())
        try harness.sut.start()

        XCTAssertEqual(harness.commands.invoke(.play), .noSuchContent)
        XCTAssertEqual(
            harness.commands.invoke(.changePlaybackPosition, payload: .position(12)),
            .commandFailed
        )
        harness.snapshots.send(snapshot(status: .playing))
        XCTAssertEqual(harness.commands.invoke(.changePlaybackPosition), .commandFailed)
    }

    /// 加载或失败状态没有稳定播放时间，拖动进度必须失败且不能调用 seek。
    func testChangePositionRejectsLoadingAndFailedSnapshots() throws {
        let harness = makeHarness(initial: snapshot(status: .loading))
        try harness.sut.start()

        XCTAssertEqual(
            harness.commands.invoke(.changePlaybackPosition, payload: .position(18)),
            .commandFailed
        )
        harness.snapshots.send(snapshot(status: .failed("offline")))
        XCTAssertEqual(
            harness.commands.invoke(.changePlaybackPosition, payload: .position(24)),
            .commandFailed
        )
        XCTAssertTrue(harness.controls.events.isEmpty)
    }

    /// 若暂停、失败或加载状态发布非零速率，锁屏会错误显示仍在播放。
    func testSnapshotMapsMetadataArtworkProgressAndPlaybackRate() throws {
        let track = SimpleMusic.MusicTrack(
            id: "track",
            title: "夜航",
            artist: "林野",
            album: "远岸",
            duration: 245,
            artworkData: onePixelPNG(),
            source: .downloaded(fileName: "track.m4a")
        )
        let harness = makeHarness(initial: PlaybackSnapshot(
            status: .playing,
            track: track,
            elapsed: 32,
            duration: 240,
            queueIndex: 0,
            queueCount: 1
        ))

        try harness.sut.start()

        let playingInfo = try XCTUnwrap(harness.infoCenter.nowPlayingInfo)
        XCTAssertEqual(playingInfo[MPMediaItemPropertyTitle] as? String, "夜航")
        XCTAssertEqual(playingInfo[MPMediaItemPropertyArtist] as? String, "林野")
        XCTAssertEqual(playingInfo[MPMediaItemPropertyAlbumTitle] as? String, "远岸")
        XCTAssertNotNil(playingInfo[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork)
        XCTAssertEqual(playingInfo[MPMediaItemPropertyPlaybackDuration] as? Double, 240)
        XCTAssertEqual(playingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double, 32)
        XCTAssertEqual(playingInfo[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 1)

        harness.snapshots.send(PlaybackSnapshot(
            status: .failed("offline"),
            track: track,
            elapsed: 33,
            duration: 240,
            queueIndex: 0,
            queueCount: 1
        ))
        XCTAssertEqual(
            harness.infoCenter.nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? Double,
            0
        )

        harness.snapshots.send(PlaybackSnapshot(
            status: .paused,
            track: track,
            elapsed: 34,
            duration: 240,
            queueIndex: 0,
            queueCount: 1
        ))
        XCTAssertEqual(
            harness.infoCenter.nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? Double,
            0
        )
    }

    /// idle 或缺少曲目时必须移除上一首歌的锁屏信息，避免显示陈旧内容。
    func testIdleOrMissingTrackClearsNowPlayingInfo() throws {
        let harness = makeHarness(initial: snapshot(status: .playing))
        try harness.sut.start()
        XCTAssertNotNil(harness.infoCenter.nowPlayingInfo)

        harness.snapshots.send(PlaybackSnapshot(status: .idle, track: snapshotTrack()))
        XCTAssertNil(harness.infoCenter.nowPlayingInfo)

        harness.snapshots.send(PlaybackSnapshot(status: .playing, track: nil))
        XCTAssertNil(harness.infoCenter.nowPlayingInfo)
    }

    /// 音频会话激活失败时，不能留下半注册的命令或订阅。
    func testAudioSessionFailurePropagatesBeforeRegistration() {
        let harness = makeHarness(initial: snapshot(status: .playing))
        harness.audioSession.error = TestError.audioSessionFailed

        XCTAssertThrowsError(try harness.sut.start()) { error in
            XCTAssertEqual(error as? TestError, .audioSessionFailed)
        }
        XCTAssertEqual(harness.commands.addCount, 0)
        XCTAssertNil(harness.infoCenter.nowPlayingInfo)
    }

    /// stop 必须撤销所有系统 target 与 Combine 订阅，且重复调用安全。
    func testStopRemovesAllTargetsAndCancelsSnapshotUpdates() throws {
        let harness = makeHarness(initial: snapshot(status: .playing))
        try harness.sut.start()
        let infoBeforeStop = harness.infoCenter.nowPlayingInfo

        harness.sut.stop()
        harness.sut.stop()
        harness.snapshots.send(snapshot(status: .paused, elapsed: 99))

        XCTAssertEqual(harness.commands.removedCommands, Set(RemotePlaybackCommand.allCases))
        XCTAssertEqual(harness.commands.removeCount, RemotePlaybackCommand.allCases.count)
        XCTAssertEqual(
            harness.infoCenter.nowPlayingInfo?[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double,
            infoBeforeStop?[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double
        )
    }

    /// 若服务释放后 target 仍存活，系统命令会继续持有无效生命周期。
    func testDeinitRemovesEveryRemoteCommandTarget() throws {
        let commands = FakeRemoteCommandRegister()
        weak var weakService: NowPlayingService?

        do {
            let service = NowPlayingService(
                snapshotPublisher: CurrentValueSubject(PlaybackSnapshot()).eraseToAnyPublisher(),
                commands: commands,
                infoCenter: FakeNowPlayingInfoCenter(),
                audioSession: FakeAudioSession(),
                controls: FakePlaybackControls().controls
            )
            weakService = service
            try service.start()
        }

        XCTAssertNil(weakService)
        XCTAssertEqual(commands.removedCommands, Set(RemotePlaybackCommand.allCases))
    }

    private func makeHarness(initial: PlaybackSnapshot) -> TestHarness {
        let snapshots = CurrentValueSubject<PlaybackSnapshot, Never>(initial)
        let commands = FakeRemoteCommandRegister()
        let infoCenter = FakeNowPlayingInfoCenter()
        let audioSession = FakeAudioSession()
        let controls = FakePlaybackControls()
        let sut = NowPlayingService(
            snapshotPublisher: snapshots.eraseToAnyPublisher(),
            commands: commands,
            infoCenter: infoCenter,
            audioSession: audioSession,
            controls: controls.controls
        )
        return TestHarness(
            sut: sut,
            snapshots: snapshots,
            commands: commands,
            infoCenter: infoCenter,
            audioSession: audioSession,
            controls: controls
        )
    }

    private func snapshot(
        status: PlaybackStatus,
        elapsed: TimeInterval = 12
    ) -> PlaybackSnapshot {
        PlaybackSnapshot(
            status: status,
            track: snapshotTrack(),
            elapsed: elapsed,
            duration: 180,
            queueIndex: 0,
            queueCount: 1
        )
    }

    private func snapshotTrack() -> SimpleMusic.MusicTrack {
        SimpleMusic.MusicTrack(
            id: "track",
            title: "Title",
            artist: "Artist",
            album: "Album",
            duration: 180,
            artworkData: nil,
            source: .downloaded(fileName: "track.m4a")
        )
    }

    private func onePixelPNG() -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1))
        return renderer.pngData { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
    }
}

@MainActor
private struct TestHarness {
    let sut: NowPlayingService
    let snapshots: CurrentValueSubject<PlaybackSnapshot, Never>
    let commands: FakeRemoteCommandRegister
    let infoCenter: FakeNowPlayingInfoCenter
    let audioSession: FakeAudioSession
    let controls: FakePlaybackControls
}

@MainActor
private final class FakeRemoteCommandRegister: RemoteCommandRegistering, @unchecked Sendable {
    private nonisolated let handlers = LockedValue([RemotePlaybackCommand: RemoteCommandHandler]())
    private var commandsByToken = [ObjectIdentifier: RemotePlaybackCommand]()
    private(set) var addedCommands = Set<RemotePlaybackCommand>()
    private(set) var removedCommands = Set<RemotePlaybackCommand>()
    private(set) var addCount = 0
    private(set) var removeCount = 0

    func addTarget(
        for command: RemotePlaybackCommand,
        handler: @escaping RemoteCommandHandler
    ) -> AnyObject {
        let token = NSObject()
        handlers.withLock { $0[command] = handler }
        commandsByToken[ObjectIdentifier(token)] = command
        addedCommands.insert(command)
        addCount += 1
        return token
    }

    func removeTarget(_ token: AnyObject, for command: RemotePlaybackCommand) {
        guard commandsByToken.removeValue(forKey: ObjectIdentifier(token)) == command else {
            return
        }
        handlers.withLock { $0.removeValue(forKey: command) }
        removedCommands.insert(command)
        removeCount += 1
    }

    nonisolated func invoke(
        _ command: RemotePlaybackCommand,
        payload: RemoteCommandPayload = .none
    ) -> MPRemoteCommandHandlerStatus {
        let handler = handlers.withLock { $0[command] }
        return handler?(payload) ?? .commandFailed
    }
}

@MainActor
private final class FakeNowPlayingInfoCenter: NowPlayingInfoWriting {
    var nowPlayingInfo: [String: Any]?
}

@MainActor
private final class FakeAudioSession: PlaybackAudioSessionConfiguring {
    var error: Error?

    func activatePlayback() throws {
        if let error { throw error }
    }
}

@MainActor
private final class FakePlaybackControls {
    enum Event: Equatable {
        case play
        case pause
        case next
        case previous
        case seek(TimeInterval)
    }

    var events = [Event]()
    var error: Error?
    var onEvent: ((Event) -> Void)?

    var controls: NowPlayingControls {
        NowPlayingControls(
            play: { [weak self] in self?.record(.play) },
            pause: { [weak self] in self?.record(.pause) },
            next: { [weak self] in
                guard let self else { return }
                if let error { throw error }
                record(.next)
            },
            previous: { [weak self] in
                guard let self else { return }
                if let error { throw error }
                record(.previous)
            },
            seek: { [weak self] elapsed in self?.record(.seek(elapsed)) }
        )
    }

    private func record(_ event: Event) {
        events.append(event)
        onEvent?(event)
    }
}

private final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Value

    init(_ value: Value) {
        storedValue = value
    }

    var value: Value {
        withLock { $0 }
    }

    @discardableResult
    func withLock<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&storedValue)
    }
}

private enum TestError: Error, Equatable {
    case controlFailed
    case audioSessionFailed
}
