import Combine
import MediaPlayer
import UIKit
import XCTest
@testable import SimpleMusic

@MainActor
final class PlayerViewControllerTests: XCTestCase {
    /// 如果空状态仍显示演示歌曲或保留可操作的播放控件，此测试应失败。
    func testEmptySnapshotShowsPlaceholderAndDisablesPlaybackControls() async throws {
        let snapshots = CurrentValueSubject<PlaybackSnapshot, Never>(PlaybackSnapshot())
        let sut = makePlayer(snapshots: snapshots)
        sut.loadViewIfNeeded()
        await Task.yield()

        let title = try XCTUnwrap(findView(identifier: "player.title", in: sut.view) as? UILabel)
        let slider = try XCTUnwrap(findView(identifier: "player.progress", in: sut.view) as? UISlider)
        let previous = try XCTUnwrap(findView(identifier: "player.previous", in: sut.view) as? UIButton)
        let toggle = try XCTUnwrap(findView(identifier: "player.toggle", in: sut.view) as? UIButton)
        let next = try XCTUnwrap(findView(identifier: "player.next", in: sut.view) as? UIButton)

        XCTAssertEqual(title.text, "尚未播放")
        XCTAssertFalse(slider.isEnabled)
        XCTAssertFalse(previous.isEnabled)
        XCTAssertFalse(toggle.isEnabled)
        XCTAssertFalse(next.isEnabled)
    }

    /// 如果真实快照没有更新元数据、状态、时间和队列位置，此测试应失败。
    func testSnapshotRendersTrackMetadataPlaybackStateAndQueuePosition() async throws {
        let snapshots = CurrentValueSubject<PlaybackSnapshot, Never>(PlaybackSnapshot())
        let sut = makePlayer(snapshots: snapshots)
        sut.loadViewIfNeeded()
        let track = makeTrack(title: "未完待续", artist: "陈粒", album: "未完待续")

        snapshots.send(PlaybackSnapshot(
            status: .playing,
            track: track,
            elapsed: 88,
            duration: 256,
            queueIndex: 1,
            queueCount: 4
        ))
        await waitUntil {
            (self.findView(identifier: "player.title", in: sut.view) as? UILabel)?.text == track.title
        }

        let title = try XCTUnwrap(findView(identifier: "player.title", in: sut.view) as? UILabel)
        let artist = try XCTUnwrap(findView(identifier: "player.artist", in: sut.view) as? UILabel)
        let album = try XCTUnwrap(findView(identifier: "player.album", in: sut.view) as? UILabel)
        let elapsed = try XCTUnwrap(findView(identifier: "player.elapsed", in: sut.view) as? UILabel)
        let remaining = try XCTUnwrap(findView(identifier: "player.remaining", in: sut.view) as? UILabel)
        let toggle = try XCTUnwrap(findView(identifier: "player.toggle", in: sut.view) as? UIButton)
        let queue = try XCTUnwrap(findView(identifier: "player.queue", in: sut.view) as? UILabel)

        XCTAssertEqual(title.text, track.title)
        XCTAssertEqual(artist.text, track.artist)
        XCTAssertEqual(album.text, track.album)
        XCTAssertEqual(elapsed.text, "1:28")
        XCTAssertEqual(remaining.text, "-2:48")
        XCTAssertEqual(toggle.accessibilityLabel, "暂停")
        XCTAssertEqual(queue.text, "第 2 / 4 首")
    }

    /// 如果拖动期间快照把滑块抢回，或结束拖动没有 seek，此测试应失败。
    func testSeekingKeepsDraggedValueUntilReleaseThenSeeks() async throws {
        let track = makeTrack()
        let snapshots = CurrentValueSubject<PlaybackSnapshot, Never>(
            PlaybackSnapshot(status: .playing, track: track, elapsed: 10, duration: 100)
        )
        var seekValues = [TimeInterval]()
        let sut = makePlayer(snapshots: snapshots, onSeek: { seekValues.append($0) })
        sut.loadViewIfNeeded()
        let slider = try XCTUnwrap(findView(identifier: "player.progress", in: sut.view) as? UISlider)
        await waitUntil { slider.value == 10 }

        slider.sendActions(for: .touchDown)
        slider.value = 44
        slider.sendActions(for: .valueChanged)
        snapshots.send(PlaybackSnapshot(status: .paused, track: track, elapsed: 70, duration: 100))
        let toggle = try XCTUnwrap(findView(identifier: "player.toggle", in: sut.view) as? UIButton)
        await waitUntil { toggle.accessibilityLabel == "播放" }

        XCTAssertEqual(slider.value, 44, accuracy: 0.01)
        slider.sendActions(for: .touchUpInside)
        XCTAssertEqual(seekValues, [44])
    }

    /// 如果按钮没有转发统一播放协调器动作，或系统音量和 AirPlay 入口缺失，此测试应失败。
    func testPlayerRoutesControlsAndIncludesSystemAudioUtilities() throws {
        let snapshots = CurrentValueSubject<PlaybackSnapshot, Never>(
            PlaybackSnapshot(status: .paused, track: makeTrack())
        )
        var toggleCount = 0
        var previousCount = 0
        var nextCount = 0
        let sut = makePlayer(
            snapshots: snapshots,
            onTogglePlay: { toggleCount += 1 },
            onPrevious: { previousCount += 1 },
            onNext: { nextCount += 1 }
        )
        sut.loadViewIfNeeded()

        try XCTUnwrap(findView(identifier: "player.toggle", in: sut.view) as? UIButton)
            .sendActions(for: .touchUpInside)
        try XCTUnwrap(findView(identifier: "player.previous", in: sut.view) as? UIButton)
            .sendActions(for: .touchUpInside)
        try XCTUnwrap(findView(identifier: "player.next", in: sut.view) as? UIButton)
            .sendActions(for: .touchUpInside)

        XCTAssertEqual(toggleCount, 1)
        XCTAssertEqual(previousCount, 1)
        XCTAssertEqual(nextCount, 1)
        XCTAssertNotNil(findView(identifier: "player.volume", in: sut.view))
        XCTAssertNotNil(findView(identifier: "player.airplay", in: sut.view))
    }

    /// 如果手机入口不是由根协调器全屏呈现共享播放器，此测试应失败。
    func testPhoneRootPresentsSharedPlayerFullScreen() throws {
        let dependencies = makeDependencies()
        let phone = try XCTUnwrap(
            AppCoordinator.makeMainViewControllerFactory(dependencies: dependencies)(.phone)
                as? MainTabBarController
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = phone
        window.makeKeyAndVisible()
        phone.loadViewIfNeeded()

        phone.onOpenPlayer?()

        let player = try XCTUnwrap(phone.presentedViewController as? PlayerViewController)
        XCTAssertEqual(player.modalPresentationStyle, .fullScreen)
    }

    /// 如果 iPad 面板不是 PadRoot child、宽度偏离 324 点或遮罩不能关闭，此测试应失败。
    func testPadRootShowsContainedPlayerPanelAndMaskDismissesIt() throws {
        let pad = PadRootViewController(dependencies: makeDependencies())
        pad.loadViewIfNeeded()
        pad.view.frame = CGRect(x: 0, y: 0, width: 834, height: 1194)
        pad.view.layoutIfNeeded()
        let panel = try XCTUnwrap(descendant(NowPlayingPanelController.self, in: pad))

        XCTAssertTrue(panel.parent === pad)
        XCTAssertTrue(descendant(PlayerViewController.self, in: panel) != nil)
        XCTAssertFalse(panel.isPresented)

        pad.onOpenPlayer?()
        pad.view.layoutIfNeeded()
        let surface = try XCTUnwrap(findView(identifier: "player.panel", in: panel.view))
        XCTAssertTrue(panel.isPresented)
        XCTAssertEqual(surface.frame.width, 324, accuracy: 0.5)
        XCTAssertEqual(surface.frame.maxX, panel.view.bounds.width, accuracy: 0.5)

        let mask = try XCTUnwrap(findView(identifier: "player.mask", in: panel.view) as? UIButton)
        mask.sendActions(for: .touchUpInside)
        XCTAssertFalse(panel.isPresented)
    }

    private func makePlayer(
        snapshots: CurrentValueSubject<PlaybackSnapshot, Never>,
        onTogglePlay: @escaping () -> Void = {},
        onPrevious: @escaping () -> Void = {},
        onNext: @escaping () -> Void = {},
        onSeek: @escaping (TimeInterval) -> Void = { _ in }
    ) -> PlayerViewController {
        PlayerViewController(
            snapshotPublisher: snapshots.eraseToAnyPublisher(),
            onTogglePlay: onTogglePlay,
            onPrevious: onPrevious,
            onNext: onNext,
            onSeek: onSeek
        )
    }

    private func makeDependencies() -> AppRootDependencies {
        let identity = NSObject()
        let viewModel = LibraryViewModel(
            library: PlayerStubMusicLibrary(),
            localStore: PlayerStubLocalMusicStore()
        )
        let snapshots = CurrentValueSubject<PlaybackSnapshot, Never>(PlaybackSnapshot())
        return AppRootDependencies(
            identity: identity,
            libraryViewModel: viewModel,
            snapshotPublisher: snapshots.eraseToAnyPublisher(),
            onPlay: { _, _ in },
            onTogglePlay: {},
            onPrevious: {},
            onNext: {},
            onSeek: { _ in }
        )
    }

    private func makeTrack(
        title: String = "歌曲",
        artist: String = "艺人",
        album: String = "专辑"
    ) -> SimpleMusic.MusicTrack {
        SimpleMusic.MusicTrack(
            id: "track",
            title: title,
            artist: artist,
            album: album,
            duration: 180,
            artworkData: nil,
            source: .downloaded(fileName: "track.mp3")
        )
    }

    private func findView(identifier: String, in root: UIView) -> UIView? {
        if root.accessibilityIdentifier == identifier { return root }
        return root.subviews.lazy.compactMap {
            self.findView(identifier: identifier, in: $0)
        }.first
    }

    private func descendant<T: UIViewController>(
        _ type: T.Type,
        in root: UIViewController
    ) -> T? {
        if let match = root as? T { return match }
        return root.children.lazy.compactMap { self.descendant(type, in: $0) }.first
    }

    private func waitUntil(
        attempts: Int = 20,
        condition: @escaping @MainActor () -> Bool
    ) async {
        for _ in 0..<attempts where !condition() {
            await Task.yield()
        }
    }
}

@MainActor
private final class PlayerStubMusicLibrary: MusicLibraryLoading {
    let authorizationStatus = MPMediaLibraryAuthorizationStatus.authorized

    func loadTracks() async throws -> [SimpleMusic.MusicTrack] { [] }
}

@MainActor
private final class PlayerStubLocalMusicStore: LocalMusicLoading {
    func loadTracks() async throws -> [SimpleMusic.MusicTrack] { [] }
}
