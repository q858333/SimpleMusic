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
        let subtitle = try XCTUnwrap(findView(identifier: "player.artist", in: sut.view) as? UILabel)
        let nowPlaying = try XCTUnwrap(findView(identifier: "player.nowPlaying", in: sut.view) as? UILabel)
        let upNext = try XCTUnwrap(findView(identifier: "player.upNext", in: sut.view) as? UILabel)
        let queue = try XCTUnwrap(findView(identifier: "player.queue", in: sut.view) as? UILabel)
        let close = try XCTUnwrap(findView(identifier: "player.close", in: sut.view) as? UIButton)
        let slider = try XCTUnwrap(findView(identifier: "player.progress", in: sut.view) as? UISlider)
        let previous = try XCTUnwrap(findView(identifier: "player.previous", in: sut.view) as? UIButton)
        let toggle = try XCTUnwrap(findView(identifier: "player.toggle", in: sut.view) as? UIButton)
        let next = try XCTUnwrap(findView(identifier: "player.next", in: sut.view) as? UIButton)

        XCTAssertEqual(title.text, L10n.text("player.empty_title"))
        XCTAssertEqual(subtitle.text, L10n.text("player.empty_subtitle"))
        XCTAssertEqual(nowPlaying.text, L10n.text("player.now_playing"))
        XCTAssertEqual(upNext.text, L10n.text("player.up_next"))
        XCTAssertEqual(queue.text, L10n.text("player.queue_empty"))
        XCTAssertEqual(close.accessibilityLabel, L10n.text("player.close_now_playing"))
        XCTAssertEqual(slider.accessibilityLabel, L10n.text("player.progress"))
        XCTAssertEqual(previous.accessibilityLabel, L10n.text("player.previous"))
        XCTAssertEqual(toggle.accessibilityLabel, L10n.text("common.play"))
        XCTAssertEqual(next.accessibilityLabel, L10n.text("player.next"))
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
        XCTAssertEqual(toggle.accessibilityLabel, L10n.text("common.pause"))
        XCTAssertEqual(queue.text, L10n.format("player.queue.position", 2, 4))
    }

    /// 如果无封面歌曲仍使用偏小的系统符号，或占位图没有居中放大，此测试应失败。
    func testPlayerUsesLargeWhitePlaceholderArtworkAboveTitle() async throws {
        let track = makeTrack(title: "无封面歌曲")
        let snapshots = CurrentValueSubject<PlaybackSnapshot, Never>(
            PlaybackSnapshot(status: .paused, track: track)
        )
        let sut = makePlayer(snapshots: snapshots)
        sut.loadViewIfNeeded()
        await waitUntil {
            self.findView(identifier: "player.artwork.placeholder", in: sut.view) != nil
        }

        let placeholder = try XCTUnwrap(
            findView(identifier: "player.artwork.placeholder", in: sut.view) as? UIImageView
        )
        sut.view.layoutIfNeeded()
        let whiteImage = try XCTUnwrap(UIImage(named: "music-note-white"))

        XCTAssertFalse(placeholder.isHidden)
        XCTAssertEqual(placeholder.image?.pngData(), whiteImage.pngData())
        XCTAssertEqual(placeholder.bounds.size, CGSize(width: 88, height: 88))
        XCTAssertEqual(placeholder.contentMode, .scaleAspectFit)
    }

    /// 如果播放页失去标题粗细对比、材质控制区或定制进度圆点，视觉层级会退回系统默认样式。
    func testPlayerUsesExpressiveTypographyMaterialControlsAndCustomProgressThumb() throws {
        let snapshots = CurrentValueSubject<PlaybackSnapshot, Never>(
            PlaybackSnapshot(status: .paused, track: makeTrack())
        )
        let sut = makePlayer(snapshots: snapshots)
        sut.loadViewIfNeeded()
        sut.view.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        sut.view.layoutIfNeeded()

        let title = try XCTUnwrap(findView(identifier: "player.title", in: sut.view) as? UILabel)
        let artist = try XCTUnwrap(findView(identifier: "player.artist", in: sut.view) as? UILabel)
        let material = try XCTUnwrap(
            findView(identifier: "player.controls.surface", in: sut.view) as? UIVisualEffectView
        )
        let slider = try XCTUnwrap(findView(identifier: "player.progress", in: sut.view) as? UISlider)
        let toggle = try XCTUnwrap(findView(identifier: "player.toggle", in: sut.view) as? UIButton)
        let titleWeight = try XCTUnwrap(fontWeight(title.font))
        let artistWeight = try XCTUnwrap(fontWeight(artist.font))

        XCTAssertTrue(material.effect is UIBlurEffect)
        XCTAssertGreaterThan(titleWeight, UIFont.Weight.bold.rawValue)
        XCTAssertLessThan(artistWeight, UIFont.Weight.regular.rawValue)
        XCTAssertEqual(slider.thumbImage(for: .normal)?.size, CGSize(width: 24, height: 24))
        XCTAssertEqual(toggle.bounds.size, CGSize(width: 62, height: 62))
        XCTAssertEqual(toggle.layer.cornerRadius, 22)
    }

    /// 如果真实封面出现后放大的默认音符仍叠在封面上，此测试应失败。
    func testPlayerHidesPlaceholderWhenRealArtworkIsAvailable() async throws {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2))
        let artworkData = renderer.pngData { context in
            UIColor.systemBlue.setFill()
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
        let track = makeTrack(title: "有封面歌曲", artworkData: artworkData)
        let snapshots = CurrentValueSubject<PlaybackSnapshot, Never>(
            PlaybackSnapshot(status: .paused, track: track)
        )
        let sut = makePlayer(snapshots: snapshots)
        sut.loadViewIfNeeded()
        let artwork = try XCTUnwrap(
            findView(identifier: "player.artwork", in: sut.view) as? UIImageView
        )
        let placeholder = try XCTUnwrap(
            findView(identifier: "player.artwork.placeholder", in: sut.view) as? UIImageView
        )
        await waitUntil { artwork.image != nil && placeholder.isHidden }

        XCTAssertTrue(placeholder.isHidden)
        XCTAssertEqual(artwork.image?.pngData(), UIImage(data: artworkData)?.pngData())
        XCTAssertEqual(artwork.contentMode, .scaleAspectFill)
    }

    /// 如果队列结束后仍保留的歌曲让无效控制继续可用，或文案误报为空，此测试应失败。
    func testQueueEndSnapshotKeepsMetadataButDisablesControlsAndShowsEndedState() async throws {
        let track = makeTrack(title: "最后一首")
        let snapshots = CurrentValueSubject<PlaybackSnapshot, Never>(
            PlaybackSnapshot(
                status: .idle,
                track: track,
                elapsed: 0,
                duration: 180,
                queueIndex: nil,
                queueCount: 3
            )
        )
        let sut = makePlayer(snapshots: snapshots)
        sut.loadViewIfNeeded()
        let queue = try XCTUnwrap(findView(identifier: "player.queue", in: sut.view) as? UILabel)
        await waitUntil { queue.text != nil }

        let title = try XCTUnwrap(findView(identifier: "player.title", in: sut.view) as? UILabel)
        let slider = try XCTUnwrap(findView(identifier: "player.progress", in: sut.view) as? UISlider)
        let previous = try XCTUnwrap(findView(identifier: "player.previous", in: sut.view) as? UIButton)
        let toggle = try XCTUnwrap(findView(identifier: "player.toggle", in: sut.view) as? UIButton)
        let next = try XCTUnwrap(findView(identifier: "player.next", in: sut.view) as? UIButton)

        XCTAssertEqual(title.text, track.title)
        XCTAssertEqual(queue.text, L10n.text("player.queue_ended"))
        XCTAssertFalse(slider.isEnabled)
        XCTAssertFalse(previous.isEnabled)
        XCTAssertFalse(toggle.isEnabled)
        XCTAssertFalse(next.isEnabled)
    }

    /// 如果控件可用状态没有遵循协调器各动作的真实状态分支，此测试应失败。
    func testPlaybackControlAvailabilityMatchesCoordinatorActionSemantics() async throws {
        let track = makeTrack()
        let snapshots = CurrentValueSubject<PlaybackSnapshot, Never>(PlaybackSnapshot())
        let sut = makePlayer(snapshots: snapshots)
        sut.loadViewIfNeeded()
        let previous = try XCTUnwrap(findView(identifier: "player.previous", in: sut.view) as? UIButton)
        let toggle = try XCTUnwrap(findView(identifier: "player.toggle", in: sut.view) as? UIButton)
        let next = try XCTUnwrap(findView(identifier: "player.next", in: sut.view) as? UIButton)
        let slider = try XCTUnwrap(findView(identifier: "player.progress", in: sut.view) as? UISlider)
        let scenarios: [(
            name: String,
            status: PlaybackStatus,
            index: Int,
            count: Int,
            previous: Bool,
            toggle: Bool,
            next: Bool,
            seek: Bool
        )] = [
            ("loading-first", .loading, 0, 3, false, false, true, false),
            ("loading-middle", .loading, 1, 3, true, false, true, false),
            ("loading-last", .loading, 2, 3, true, false, false, false),
            ("playing-first", .playing, 0, 3, false, true, true, true),
            ("playing-middle", .playing, 1, 3, true, true, true, true),
            ("playing-last", .playing, 2, 3, true, true, false, true),
            ("paused-first", .paused, 0, 3, false, true, true, true),
            ("paused-middle", .paused, 1, 3, true, true, true, true),
            ("paused-last", .paused, 2, 3, true, true, false, true),
            ("failed-first", .failed("失败"), 0, 2, false, false, true, false),
            ("failed-middle", .failed("失败"), 1, 3, true, false, true, false),
            ("failed-last", .failed("失败"), 2, 3, true, false, false, false)
        ]

        for scenario in scenarios {
            snapshots.send(PlaybackSnapshot(
                status: scenario.status,
                track: track,
                elapsed: 10,
                duration: 100,
                queueIndex: scenario.index,
                queueCount: scenario.count
            ))
            await waitUntil {
                previous.isEnabled == scenario.previous
                    && toggle.isEnabled == scenario.toggle
                    && next.isEnabled == scenario.next
                    && slider.isEnabled == scenario.seek
            }

            XCTAssertEqual(previous.isEnabled, scenario.previous, scenario.name)
            XCTAssertEqual(toggle.isEnabled, scenario.toggle, scenario.name)
            XCTAssertEqual(next.isEnabled, scenario.next, scenario.name)
            XCTAssertEqual(slider.isEnabled, scenario.seek, scenario.name)
        }
    }

    /// 如果拖动期间快照把滑块抢回，或结束拖动没有 seek，此测试应失败。
    func testSeekingKeepsDraggedValueUntilReleaseThenSeeks() async throws {
        let track = makeTrack()
        let snapshots = CurrentValueSubject<PlaybackSnapshot, Never>(
            PlaybackSnapshot(
                status: .playing,
                track: track,
                elapsed: 10,
                duration: 100,
                queueIndex: 0,
                queueCount: 1
            )
        )
        var seekValues = [TimeInterval]()
        let sut = makePlayer(snapshots: snapshots, onSeek: { seekValues.append($0) })
        sut.loadViewIfNeeded()
        let slider = try XCTUnwrap(findView(identifier: "player.progress", in: sut.view) as? UISlider)
        await waitUntil { slider.value == 10 }

        slider.sendActions(for: .touchDown)
        slider.value = 44
        slider.sendActions(for: .valueChanged)
        snapshots.send(PlaybackSnapshot(
            status: .paused,
            track: track,
            elapsed: 70,
            duration: 100,
            queueIndex: 0,
            queueCount: 1
        ))
        let toggle = try XCTUnwrap(findView(identifier: "player.toggle", in: sut.view) as? UIButton)
        await waitUntil { toggle.accessibilityLabel == L10n.text("common.play") }

        XCTAssertEqual(slider.value, 44, accuracy: 0.01)
        slider.sendActions(for: .touchUpInside)
        XCTAssertEqual(seekValues, [44])
    }

    /// 如果拖动中播放失败，随后到达的 touchUp 仍提交无效 seek，此测试应失败。
    func testSeekingDoesNotCommitAfterSnapshotBecomesUnseekable() async throws {
        let track = makeTrack()
        let snapshots = CurrentValueSubject<PlaybackSnapshot, Never>(PlaybackSnapshot(
            status: .playing,
            track: track,
            elapsed: 10,
            duration: 100,
            queueIndex: 1,
            queueCount: 3
        ))
        var seekValues = [TimeInterval]()
        let sut = makePlayer(snapshots: snapshots, onSeek: { seekValues.append($0) })
        sut.loadViewIfNeeded()
        let slider = try XCTUnwrap(findView(identifier: "player.progress", in: sut.view) as? UISlider)
        await waitUntil { slider.value == 10 }

        slider.sendActions(for: .touchDown)
        slider.value = 44
        slider.sendActions(for: .valueChanged)
        snapshots.send(PlaybackSnapshot(
            status: .failed("失败"),
            track: track,
            elapsed: 20,
            duration: 100,
            queueIndex: 1,
            queueCount: 3
        ))
        await waitUntil { !slider.isEnabled }
        slider.sendActions(for: .touchUpInside)

        XCTAssertTrue(seekValues.isEmpty)
    }

    /// 如果失败快照没有取消拖动，缺少 touchUp 时恢复播放仍会保留旧拖动值，此测试应失败。
    func testFailedSnapshotCancelsSeekingSoPlayableSnapshotRefreshesProgress() async throws {
        let track = makeTrack()
        let snapshots = CurrentValueSubject<PlaybackSnapshot, Never>(PlaybackSnapshot(
            status: .playing,
            track: track,
            elapsed: 10,
            duration: 100,
            queueIndex: 1,
            queueCount: 3
        ))
        let sut = makePlayer(snapshots: snapshots)
        sut.loadViewIfNeeded()
        let slider = try XCTUnwrap(findView(identifier: "player.progress", in: sut.view) as? UISlider)
        await waitUntil { slider.value == 10 }

        slider.sendActions(for: .touchDown)
        slider.value = 44
        snapshots.send(PlaybackSnapshot(
            status: .failed("失败"),
            track: track,
            elapsed: 20,
            duration: 100,
            queueIndex: 1,
            queueCount: 3
        ))
        await waitUntil { !slider.isEnabled }
        snapshots.send(PlaybackSnapshot(
            status: .playing,
            track: track,
            elapsed: 76,
            duration: 100,
            queueIndex: 1,
            queueCount: 3
        ))
        await waitUntil { slider.isEnabled }

        XCTAssertEqual(slider.value, 76, accuracy: 0.01)
    }

    /// 如果空快照没有取消拖动，新歌曲进度会被旧手势锁住且迟到 touchUp 会误 seek。
    func testEmptySnapshotCancelsSeekingBeforeNextTrackSnapshot() async throws {
        let firstTrack = makeTrack(title: "第一首")
        let nextTrack = makeTrack(title: "第二首")
        let snapshots = CurrentValueSubject<PlaybackSnapshot, Never>(PlaybackSnapshot(
            status: .playing,
            track: firstTrack,
            elapsed: 10,
            duration: 100,
            queueIndex: 0,
            queueCount: 2
        ))
        var seekValues = [TimeInterval]()
        let sut = makePlayer(snapshots: snapshots, onSeek: { seekValues.append($0) })
        sut.loadViewIfNeeded()
        let slider = try XCTUnwrap(findView(identifier: "player.progress", in: sut.view) as? UISlider)
        let title = try XCTUnwrap(findView(identifier: "player.title", in: sut.view) as? UILabel)
        await waitUntil { slider.value == 10 }

        slider.sendActions(for: .touchDown)
        slider.value = 44
        slider.sendActions(for: .valueChanged)
        snapshots.send(PlaybackSnapshot())
        await waitUntil { title.text == L10n.text("player.empty_title") }
        snapshots.send(PlaybackSnapshot(
            status: .playing,
            track: nextTrack,
            elapsed: 76,
            duration: 120,
            queueIndex: 0,
            queueCount: 1
        ))
        await waitUntil { title.text == nextTrack.title && slider.isEnabled }

        XCTAssertEqual(slider.value, 76, accuracy: 0.01)
        slider.sendActions(for: .touchUpInside)
        XCTAssertTrue(seekValues.isEmpty)
    }

    /// 如果辅助功能只发送 valueChanged 时没有立即 seek，此测试应失败。
    func testNonTrackingProgressChangeSeeksImmediately() async throws {
        let snapshots = CurrentValueSubject<PlaybackSnapshot, Never>(
            PlaybackSnapshot(
                status: .paused,
                track: makeTrack(),
                elapsed: 10,
                duration: 100,
                queueIndex: 0,
                queueCount: 1
            )
        )
        var seekValues = [TimeInterval]()
        let sut = makePlayer(snapshots: snapshots, onSeek: { seekValues.append($0) })
        sut.loadViewIfNeeded()
        let slider = try XCTUnwrap(findView(identifier: "player.progress", in: sut.view) as? UISlider)
        await waitUntil { slider.maximumValue == 100 }

        slider.value = 36
        slider.sendActions(for: .valueChanged)

        XCTAssertEqual(seekValues, [36])
    }

    /// 如果按钮没有转发统一播放协调器动作，或系统音量和 AirPlay 入口缺失，此测试应失败。
    func testPlayerRoutesControlsAndIncludesSystemAudioUtilities() throws {
        let snapshots = CurrentValueSubject<PlaybackSnapshot, Never>(
            PlaybackSnapshot(
                status: .paused,
                track: makeTrack(),
                queueIndex: 0,
                queueCount: 1
            )
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
        let toolbar = try XCTUnwrap(
            findView(identifier: "player.toolbar", in: sut.view) as? UIToolbar
        )
        XCTAssertNotNil(
            toolbar.items?.compactMap(\.customView)
                .first { $0.accessibilityIdentifier == "player.airplay" }
        )
    }

    /// 底部工具栏必须同时提供更多和红色 AirPlay，更多按钮直接打开混响设置弹窗。
    func testBottomToolbarPresentsAudioEffectsAndRoutesChanges() async throws {
        let track = makeTrack()
        let snapshots = CurrentValueSubject<PlaybackSnapshot, Never>(
            PlaybackSnapshot(
                status: .paused,
                track: track,
                queueIndex: 0,
                queueCount: 1,
                audioEffectSettings: AudioEffectSettings(preset: .smallRoom, wetDryMix: 25),
                queue: [track]
            )
        )
        var updates = [AudioEffectSettings]()
        let sut = makePlayer(
            snapshots: snapshots,
            onUpdateAudioEffect: { updates.append($0) }
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = sut
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        sut.loadViewIfNeeded()
        sut.view.layoutIfNeeded()

        let toolbar = try XCTUnwrap(
            findView(identifier: "player.toolbar", in: sut.view) as? UIToolbar
        )
        XCTAssertEqual(
            toolbar.frame.maxY,
            sut.view.safeAreaLayoutGuide.layoutFrame.maxY,
            accuracy: 1
        )
        let toolbarViews = toolbar.items?.compactMap(\.customView) ?? []
        XCTAssertNotNil(toolbarViews.first { $0.accessibilityIdentifier == "player.airplay" })
        let more = try XCTUnwrap(
            toolbarViews.first { $0.accessibilityIdentifier == "player.more" } as? UIButton
        )
        await waitUntil(attempts: 2_000) { toolbar.isUserInteractionEnabled && more.isEnabled }
        more.sendActions(for: .touchUpInside)
        await waitUntil(attempts: 2_000) { sut.presentedViewController != nil }

        let navigation = try XCTUnwrap(sut.presentedViewController as? UINavigationController)
        let effects = try XCTUnwrap(navigation.topViewController as? AudioEffectsViewController)
        effects.selectPresetForTesting(.cathedral)
        effects.setWetDryMixForTesting(64)

        XCTAssertEqual(updates.last, AudioEffectSettings(preset: .cathedral, wetDryMix: 64))
    }

    /// 播放模式按钮必须位于上一首左侧，并随快照显示列表、单曲循环和随机状态。
    func testPlaybackModeButtonPrecedesPreviousAndRendersEveryMode() async throws {
        let snapshots = CurrentValueSubject<PlaybackSnapshot, Never>(
            PlaybackSnapshot(
                status: .paused,
                track: makeTrack(),
                queueIndex: 0,
                queueCount: 3,
                playbackMode: .list
            )
        )
        var cycleCount = 0
        let sut = makePlayer(
            snapshots: snapshots,
            onCyclePlaybackMode: { cycleCount += 1 }
        )
        sut.loadViewIfNeeded()
        sut.view.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        sut.view.layoutIfNeeded()

        let mode = try XCTUnwrap(
            findView(identifier: "player.playbackMode", in: sut.view) as? UIButton
        )
        let previous = try XCTUnwrap(
            findView(identifier: "player.previous", in: sut.view) as? UIButton
        )
        await waitUntil { mode.accessibilityLabel == L10n.text("player.mode.list") }

        XCTAssertLessThan(mode.frame.maxX, previous.frame.minX)
        XCTAssertEqual(mode.accessibilityLabel, L10n.text("player.mode.list"))
        XCTAssertEqual(
            mode.image(for: .normal)?.pngData(),
            UIImage(systemName: "list.bullet")?.pngData()
        )

        snapshots.send(PlaybackSnapshot(
            status: .paused,
            track: makeTrack(),
            queueIndex: 0,
            queueCount: 3,
            playbackMode: .repeatOne
        ))
        await waitUntil { mode.accessibilityLabel == L10n.text("player.mode.repeat_one") }
        XCTAssertEqual(
            mode.image(for: .normal)?.pngData(),
            UIImage(systemName: "repeat.1")?.pngData()
        )

        snapshots.send(PlaybackSnapshot(
            status: .paused,
            track: makeTrack(),
            queueIndex: 0,
            queueCount: 3,
            playbackMode: .shuffle
        ))
        await waitUntil { mode.accessibilityLabel == L10n.text("player.mode.shuffle") }
        XCTAssertEqual(
            mode.image(for: .normal)?.pngData(),
            UIImage(systemName: "shuffle")?.pngData()
        )

        mode.sendActions(for: .touchUpInside)
        XCTAssertEqual(cycleCount, 1)
    }

    /// 播放列表按钮必须位于下一首右侧，并展示当前队列、当前项和可切换歌曲。
    func testQueueButtonFollowsNextAndPresentsSelectableCurrentQueue() async throws {
        let tracks = [
            makeTrack(id: "queue-first", title: "第一首"),
            makeTrack(id: "queue-current", title: "当前歌曲"),
            makeTrack(id: "queue-last", title: "最后一首")
        ]
        let snapshots = CurrentValueSubject<PlaybackSnapshot, Never>(
            PlaybackSnapshot(
                status: .paused,
                track: tracks[1],
                queueIndex: 1,
                queueCount: tracks.count,
                queue: tracks
            )
        )
        var selectedIndices = [Int]()
        let sut = makePlayer(
            snapshots: snapshots,
            onSelectQueueItem: { selectedIndices.append($0) }
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = sut
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        sut.view.layoutIfNeeded()

        let next = try XCTUnwrap(
            findView(identifier: "player.next", in: sut.view) as? UIButton
        )
        let queueButton = try XCTUnwrap(
            findView(identifier: "player.showQueue", in: sut.view) as? UIButton
        )
        await waitUntil(attempts: 2_000) { queueButton.isEnabled }
        XCTAssertTrue(queueButton.isEnabled)
        XCTAssertNotNil(queueButton.image(for: .normal))
        XCTAssertGreaterThan(queueButton.frame.minX, next.frame.maxX)

        queueButton.sendActions(for: .touchUpInside)
        await waitUntil(attempts: 2_000) { sut.presentedViewController != nil }
        let navigation = try XCTUnwrap(sut.presentedViewController as? UINavigationController)
        let queueController = try XCTUnwrap(
            navigation.topViewController as? PlaybackQueueViewController
        )
        let table = try XCTUnwrap(
            findView(identifier: "player.queueList", in: queueController.view) as? UITableView
        )

        XCTAssertEqual(table.numberOfRows(inSection: 0), tracks.count)
        let currentCell = try XCTUnwrap(
            table.dataSource?.tableView(table, cellForRowAt: IndexPath(row: 1, section: 0))
        )
        XCTAssertEqual(currentCell.textLabel?.text, "当前歌曲")
        XCTAssertEqual(currentCell.accessoryType, .checkmark)

        table.delegate?.tableView?(table, didSelectRowAt: IndexPath(row: 2, section: 0))
        XCTAssertEqual(selectedIndices, [2])
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
        XCTAssertEqual(mask.accessibilityLabel, L10n.text("player.close_now_playing"))
        mask.sendActions(for: .touchUpInside)
        XCTAssertFalse(panel.isPresented)
    }

    /// 如果首首歌曲出现后没有提示入口，iPad 用户无法知道右侧播放页从哪里打开。
    func testPadPlayerGuideAppearsForFirstTrackAndStaysDismissedAfterOpening() async throws {
        let suiteName = "PlayerViewControllerTests.pad-guide.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let snapshots = CurrentValueSubject<PlaybackSnapshot, Never>(PlaybackSnapshot())
        let dependencies = makeDependencies(snapshots: snapshots)
        let pad = PadRootViewController(
            dependencies: dependencies,
            playerGuideDefaults: defaults
        )
        pad.loadViewIfNeeded()
        pad.view.frame = CGRect(x: 0, y: 0, width: 834, height: 1194)
        pad.view.layoutIfNeeded()
        let guide = try XCTUnwrap(findView(identifier: "pad.playerGuide", in: pad.view))

        XCTAssertTrue(guide.isHidden)
        snapshots.send(PlaybackSnapshot(
            status: .playing,
            track: makeTrack(),
            elapsed: 0,
            duration: 180,
            queueIndex: 0,
            queueCount: 1
        ))
        await waitUntil { !guide.isHidden }

        XCTAssertFalse(guide.isHidden)
        XCTAssertTrue(guide.isAccessibilityElement)
        XCTAssertEqual(guide.accessibilityLabel, L10n.text("pad.player_guide"))

        let openButton = try XCTUnwrap(
            findView(identifier: "mini.open", in: pad.view) as? UIButton
        )
        openButton.sendActions(for: UIControl.Event.touchUpInside)
        XCTAssertTrue(guide.isHidden)

        let nextPad = PadRootViewController(
            dependencies: dependencies,
            playerGuideDefaults: defaults
        )
        nextPad.loadViewIfNeeded()
        let nextGuide = try XCTUnwrap(
            findView(identifier: "pad.playerGuide", in: nextPad.view)
        )
        let nextMiniPlayer = try XCTUnwrap(
            findView(identifier: "mini.open", in: nextPad.view)?.superview
        )
        await waitUntil { !nextMiniPlayer.isHidden }
        XCTAssertFalse(nextMiniPlayer.isHidden)
        XCTAssertTrue(nextGuide.isHidden)
    }

    /// 如果气泡没有向下箭头，或箭头偏离气泡底部，就不能清楚指向下方迷你播放器。
    func testPadPlayerGuideArrowPointsDownAtMiniPlayer() async throws {
        let suiteName = "PlayerViewControllerTests.pad-guide-arrow.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let snapshots = CurrentValueSubject<PlaybackSnapshot, Never>(PlaybackSnapshot())
        let pad = PadRootViewController(
            dependencies: makeDependencies(snapshots: snapshots),
            playerGuideDefaults: defaults
        )
        pad.loadViewIfNeeded()
        pad.view.frame = CGRect(x: 0, y: 0, width: 834, height: 1194)
        pad.view.layoutIfNeeded()

        snapshots.send(PlaybackSnapshot(
            status: .playing,
            track: makeTrack(),
            elapsed: 0,
            duration: 180,
            queueIndex: 0,
            queueCount: 1
        ))
        let guide = try XCTUnwrap(findView(identifier: "pad.playerGuide", in: pad.view))
        await waitUntil { !guide.isHidden }
        pad.view.layoutIfNeeded()

        let arrow = try XCTUnwrap(findView(identifier: "pad.playerGuide.arrow", in: guide))
        let miniPlayer = try XCTUnwrap(findView(identifier: "mini.open", in: pad.view)?.superview)
        let shapeLayer = try XCTUnwrap(arrow.layer as? CAShapeLayer)
        let path = try XCTUnwrap(shapeLayer.path)
        let arrowFrame = arrow.convert(arrow.bounds, to: pad.view)
        let guideFrame = guide.convert(guide.bounds, to: pad.view)
        let miniFrame = miniPlayer.convert(miniPlayer.bounds, to: pad.view)

        XCTAssertEqual(arrowFrame.maxY, guideFrame.maxY, accuracy: 0.5)
        XCTAssertEqual(arrowFrame.midX, guideFrame.midX, accuracy: 0.5)
        XCTAssertLessThan(arrowFrame.maxY, miniFrame.minY)
        XCTAssertTrue(path.contains(CGPoint(x: arrow.bounds.midX, y: arrow.bounds.maxY - 1)))
        XCTAssertFalse(path.contains(CGPoint(x: 1, y: arrow.bounds.maxY - 1)))
    }

    /// 如果主体或箭头带描边，引导会显得生硬，不符合轻量气泡的视觉要求。
    func testPadPlayerGuideUsesFillWithoutBorder() throws {
        let pad = PadRootViewController(dependencies: makeDependencies())
        pad.loadViewIfNeeded()
        pad.view.frame = CGRect(x: 0, y: 0, width: 834, height: 1194)
        pad.view.layoutIfNeeded()

        let guide = try XCTUnwrap(findView(identifier: "pad.playerGuide", in: pad.view))
        let body = try XCTUnwrap(findView(identifier: "pad.playerGuide.body", in: guide))
        let arrow = try XCTUnwrap(findView(identifier: "pad.playerGuide.arrow", in: guide))
        let arrowLayer = try XCTUnwrap(arrow.layer as? CAShapeLayer)

        XCTAssertEqual(body.layer.borderWidth, 0)
        XCTAssertNil(arrowLayer.strokeColor)
    }

    /// 如果曲目消失后引导仍悬浮，提示会指向已经隐藏的迷你播放器。
    func testPadPlayerGuideHidesWhenPlaybackBecomesEmptyAndKeepsAccessibleLayout() async throws {
        let suiteName = "PlayerViewControllerTests.pad-guide-empty.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let snapshots = CurrentValueSubject<PlaybackSnapshot, Never>(PlaybackSnapshot())
        let pad = PadRootViewController(
            dependencies: makeDependencies(snapshots: snapshots),
            playerGuideDefaults: defaults
        )
        pad.loadViewIfNeeded()
        pad.view.frame = CGRect(x: 0, y: 0, width: 834, height: 1194)
        pad.view.layoutIfNeeded()
        let guide = try XCTUnwrap(findView(identifier: "pad.playerGuide", in: pad.view))

        snapshots.send(PlaybackSnapshot(
            status: .paused,
            track: makeTrack(),
            elapsed: 12,
            duration: 180,
            queueIndex: 0,
            queueCount: 1
        ))
        await waitUntil { !guide.isHidden }
        pad.view.layoutIfNeeded()

        XCTAssertGreaterThanOrEqual(guide.bounds.height, 44)
        XCTAssertFalse(guide.hasAmbiguousLayout)

        snapshots.send(PlaybackSnapshot())
        await waitUntil { guide.isHidden }
        XCTAssertTrue(guide.isHidden)
    }

    /// 如果面板显示时没有建立模态辅助功能边界，或关闭后没有撤销，此测试应失败。
    func testPadPanelAccessibilityModalStateFollowsPresentationLifecycle() throws {
        let pad = PadRootViewController(dependencies: makeDependencies())
        pad.loadViewIfNeeded()
        let panel = try XCTUnwrap(descendant(NowPlayingPanelController.self, in: pad))

        panel.show(animated: false)
        XCTAssertTrue(panel.view.accessibilityViewIsModal)

        panel.dismissPanel(animated: false)
        XCTAssertFalse(panel.view.accessibilityViewIsModal)
        XCTAssertTrue(panel.view.isHidden)
    }

    /// 如果“减弱动态效果”仍启动侧栏动画，关闭后的隐藏状态不会同步完成，此测试应失败。
    func testPadPanelCompletesTransitionsImmediatelyWhenReduceMotionIsEnabled() throws {
        let snapshots = CurrentValueSubject<PlaybackSnapshot, Never>(PlaybackSnapshot())
        let player = makePlayer(snapshots: snapshots)
        let panel = NowPlayingPanelController(
            playerViewController: player,
            isReduceMotionEnabled: { true }
        )
        let host = UIViewController()
        host.loadViewIfNeeded()
        host.view.frame = CGRect(x: 0, y: 0, width: 834, height: 1194)
        host.addChild(panel)
        host.view.addSubview(panel.view)
        panel.view.frame = host.view.bounds
        panel.didMove(toParent: host)

        panel.show()
        host.view.layoutIfNeeded()
        let surface = try XCTUnwrap(findView(identifier: "player.panel", in: panel.view))
        XCTAssertEqual(surface.frame.maxX, panel.view.bounds.width, accuracy: 0.5)

        panel.dismissPanel()
        XCTAssertTrue(panel.view.isHidden)
        XCTAssertFalse(panel.view.accessibilityViewIsModal)
    }

    private func makePlayer(
        snapshots: CurrentValueSubject<PlaybackSnapshot, Never>,
        onTogglePlay: @escaping () -> Void = {},
        onPrevious: @escaping () -> Void = {},
        onNext: @escaping () -> Void = {},
        onSeek: @escaping (TimeInterval) -> Void = { _ in },
        onCyclePlaybackMode: @escaping () -> Void = {},
        onSelectQueueItem: @escaping (Int) -> Void = { _ in },
        onUpdateAudioEffect: @escaping (AudioEffectSettings) -> Void = { _ in }
    ) -> PlayerViewController {
        PlayerViewController(
            snapshotPublisher: snapshots.eraseToAnyPublisher(),
            onTogglePlay: onTogglePlay,
            onPrevious: onPrevious,
            onNext: onNext,
            onSeek: onSeek,
            onCyclePlaybackMode: onCyclePlaybackMode,
            onSelectQueueItem: onSelectQueueItem,
            onUpdateAudioEffect: onUpdateAudioEffect
        )
    }

    private func makeDependencies() -> AppRootDependencies {
        makeDependencies(
            snapshots: CurrentValueSubject<PlaybackSnapshot, Never>(PlaybackSnapshot())
        )
    }

    private func makeDependencies(
        snapshots: CurrentValueSubject<PlaybackSnapshot, Never>
    ) -> AppRootDependencies {
        let identity = NSObject()
        let viewModel = LibraryViewModel(
            library: PlayerStubMusicLibrary(),
            localStore: PlayerStubLocalMusicStore()
        )
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
        id: String = "track",
        title: String = "歌曲",
        artist: String = "艺人",
        album: String = "专辑",
        artworkData: Data? = nil
    ) -> SimpleMusic.MusicTrack {
        SimpleMusic.MusicTrack(
            id: id,
            title: title,
            artist: artist,
            album: album,
            duration: 180,
            artworkData: artworkData,
            source: .downloaded(fileName: "track.mp3")
        )
    }

    private func findView(identifier: String, in root: UIView) -> UIView? {
        if root.accessibilityIdentifier == identifier { return root }
        return root.subviews.lazy.compactMap {
            self.findView(identifier: identifier, in: $0)
        }.first
    }

    private func fontWeight(_ font: UIFont) -> CGFloat? {
        let traits = font.fontDescriptor.object(forKey: .traits) as? [UIFontDescriptor.TraitKey: Any]
        if let value = traits?[.weight] as? CGFloat { return value }
        return (traits?[.weight] as? NSNumber).map { CGFloat($0.doubleValue) }
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
