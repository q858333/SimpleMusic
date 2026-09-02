import Combine
import CoreData
import MediaPlayer
import UIKit
import XCTest
@testable import SimpleMusic

final class LibraryViewModelTests: XCTestCase {
    /// 如果合并时重建歌曲或丢失来源字段，此测试应失败。
    @MainActor
    func testReloadMergesSystemAndDownloadedTracksWithoutDroppingSource() async {
        let systemTrack = makeTrack(id: "system-1", source: .system(persistentID: 1))
        let downloadedTrack = makeTrack(
            id: "download-1",
            source: .downloaded(fileName: "download-1.m4a")
        )
        let sut = LibraryViewModel(
            library: StubMusicLibrary(tracks: [systemTrack]),
            localStore: StubLocalMusicStore(tracks: [downloadedTrack])
        )

        await sut.reload()

        XCTAssertEqual(Set(sut.tracks), Set([systemTrack, downloadedTrack]))
    }

    /// 如果任一来源失败会清空另一来源，或失败没有成为可展示状态，此测试应失败。
    @MainActor
    func testReloadKeepsSuccessfulSourceWhenOtherSourceFails() async {
        let downloadedTrack = makeTrack(
            id: "download-1",
            source: .downloaded(fileName: "download-1.m4a")
        )
        let sut = LibraryViewModel(
            library: StubMusicLibrary(error: TestError.unavailable),
            localStore: StubLocalMusicStore(tracks: [downloadedTrack])
        )

        await sut.reload()

        XCTAssertEqual(sut.tracks, [downloadedTrack])
        guard case .failed = sut.systemState else {
            return XCTFail("系统来源失败应暴露 failed section state")
        }
        XCTAssertEqual(sut.localState, .loaded)
    }

    /// 如果搜索漏掉任一字段、区分大小写或音调符号，此测试应失败。
    @MainActor
    func testSearchMatchesTitleArtistAndAlbumCaseAndDiacriticInsensitively() async {
        let titleMatch = makeTrack(id: "title", title: "Café del Mar")
        let artistMatch = makeTrack(id: "artist", artist: "CHEN Li")
        let albumMatch = makeTrack(id: "album", album: "Núbes")
        let sut = LibraryViewModel(
            library: StubMusicLibrary(tracks: [titleMatch, artistMatch, albumMatch]),
            localStore: StubLocalMusicStore(tracks: [])
        )
        await sut.reload()

        XCTAssertEqual(sut.filter(query: "CAFE").map(\.id), [titleMatch.id])
        XCTAssertEqual(sut.filter(query: "chen").map(\.id), [artistMatch.id])
        XCTAssertEqual(sut.filter(query: "NUBES").map(\.id), [albumMatch.id])
        XCTAssertEqual(sut.filter(query: "  \n").map(\.id), sut.tracks.map(\.id))
    }

    /// 如果系统来源悬挂时本地来源尚未启动或不能先发布，此测试应失败。
    @MainActor
    func testReloadPublishesLocalSourceWhileSystemSourceIsPending() async {
        let localTrack = makeTrack(
            id: "local",
            source: .downloaded(fileName: "local.m4a")
        )
        let library = DeferredMusicLibrary()
        let localStore = DeferredLocalMusicStore()
        let sut = LibraryViewModel(
            library: library,
            localStore: localStore
        )

        let reload = Task { await sut.reload() }
        let bothSourcesStarted = await eventually {
            library.requestCount == 1 && localStore.requestCount == 1
        }
        XCTAssertTrue(bothSourcesStarted, "同一 reload 必须并发启动两个来源")

        if localStore.requestCount == 1 {
            localStore.resumeRequest(at: 0, with: [localTrack])
        }
        let localPublished = await eventually {
            sut.localState == .loaded && sut.tracks == [localTrack]
        }
        XCTAssertTrue(localPublished, "系统悬挂时本地结果应立即成为可展示状态")
        XCTAssertEqual(sut.systemState, .loading)

        await finishReloads(
            [reload],
            expectedRequests: 1,
            library: library,
            localStore: localStore
        )
    }

    /// 如果本地来源悬挂时系统来源尚未启动或不能先发布，此测试应失败。
    @MainActor
    func testReloadPublishesSystemSourceWhileLocalSourceIsPending() async {
        let systemTrack = makeTrack(id: "system")
        let library = DeferredMusicLibrary()
        let localStore = DeferredLocalMusicStore()
        let sut = LibraryViewModel(library: library, localStore: localStore)

        let reload = Task { await sut.reload() }
        let bothSourcesStarted = await eventually {
            library.requestCount == 1 && localStore.requestCount == 1
        }
        XCTAssertTrue(bothSourcesStarted, "同一 reload 必须并发启动两个来源")

        if library.requestCount == 1 {
            library.resumeRequest(at: 0, with: [systemTrack])
        }
        let systemPublished = await eventually {
            sut.systemState == .loaded && sut.tracks == [systemTrack]
        }
        XCTAssertTrue(systemPublished, "本地悬挂时系统结果应立即成为可展示状态")
        XCTAssertEqual(sut.localState, .loading)

        await finishReloads(
            [reload],
            expectedRequests: 1,
            library: library,
            localStore: localStore
        )
    }

    /// 如果系统结果发布前不读取最新权限，查询期间撤权仍会把系统歌曲显示为 loaded。
    @MainActor
    func testReloadKeepsLocalTracksWhenSystemPermissionIsRevokedDuringQuery() async {
        for revokedStatus in [
            MPMediaLibraryAuthorizationStatus.denied,
            .restricted
        ] {
            let systemTrack = makeTrack(id: "revoked-system")
            let localTrack = makeTrack(
                id: "kept-local",
                source: .downloaded(fileName: "kept-local.m4a")
            )
            let library = DeferredMusicLibrary()
            let sut = LibraryViewModel(
                library: library,
                localStore: StubLocalMusicStore(tracks: [localTrack])
            )

            let reload = Task { await sut.reload() }
            let queryStarted = await eventually { library.requestCount == 1 }
            let localPublished = await eventually {
                sut.localState == .loaded && sut.tracks == [localTrack]
            }
            XCTAssertTrue(queryStarted)
            XCTAssertTrue(localPublished)

            library.authorizationStatus = revokedStatus
            library.resumeRequestIfPending(at: 0, with: [systemTrack])
            await reload.value

            XCTAssertEqual(sut.systemState, .permissionRequired)
            XCTAssertEqual(sut.localState, .loaded)
            XCTAssertEqual(sut.tracks, [localTrack])
        }
    }

    /// 查询完成时最新状态仍为 authorized，应发布有效结果而非记住中途短暂撤权。
    @MainActor
    func testReloadPublishesSystemResultWhenLatestAuthorizationIsAuthorized() async {
        let systemTrack = makeTrack(id: "still-authorized")
        let library = DeferredMusicLibrary()
        let sut = LibraryViewModel(
            library: library,
            localStore: StubLocalMusicStore(tracks: [])
        )

        let reload = Task { await sut.reload() }
        let queryStarted = await eventually { library.requestCount == 1 }
        XCTAssertTrue(queryStarted)

        library.authorizationStatus = .denied
        library.authorizationStatus = .authorized
        library.resumeRequestIfPending(at: 0, with: [systemTrack])
        await reload.value

        XCTAssertEqual(sut.systemState, .loaded)
        XCTAssertEqual(sut.tracks, [systemTrack])
    }

    /// 多个生命周期事件到达时只能有一代在读；期间发生的变化合并为一次后续刷新。
    @MainActor
    func testRequestReloadCoalescesConcurrentEventsWithoutDroppingFollowUp() async {
        let library = DeferredMusicLibrary()
        let localStore = DeferredLocalMusicStore()
        let sut = LibraryViewModel(library: library, localStore: localStore)
        let requests = (0..<3).map { _ in Task { await sut.requestReload() } }

        let firstStarted = await eventually {
            library.requestCount >= 1 && localStore.requestCount >= 1
        }
        XCTAssertTrue(firstStarted)
        XCTAssertEqual(library.requestCount, 1)
        XCTAssertEqual(localStore.requestCount, 1)

        let initiallyStarted = max(library.requestCount, localStore.requestCount)
        for index in 0..<initiallyStarted {
            library.resumeRequestIfPending(at: index, with: [])
            localStore.resumeRequestIfPending(at: index, with: [])
        }
        let followUpStarted = await eventually {
            library.requestCount >= 2 && localStore.requestCount >= 2
        }
        if followUpStarted {
            library.resumeRequestIfPending(at: 1, with: [])
            localStore.resumeRequestIfPending(at: 1, with: [])
        }
        for request in requests { await request.value }

        XCTAssertEqual(library.requestCount, 2)
        XCTAssertEqual(localStore.requestCount, 2)
    }

    /// 首次暂不授权后在设置中允许，下一次共享刷新必须真正载入系统歌曲。
    @MainActor
    func testRequestReloadShowsSystemTracksAfterAuthorizationChangesToAllowed() async {
        let systemTrack = makeTrack(id: "newly-authorized")
        let library = DeferredMusicLibrary(authorizationStatus: .notDetermined)
        let sut = LibraryViewModel(
            library: library,
            localStore: StubLocalMusicStore(tracks: [])
        )

        await sut.requestReload()
        XCTAssertEqual(sut.systemState, .permissionRequired)
        XCTAssertTrue(sut.tracks.isEmpty)

        library.authorizationStatus = .authorized
        let refresh = Task { await sut.requestReload() }
        let queryStarted = await eventually { library.requestCount == 1 }
        XCTAssertTrue(queryStarted)
        library.resumeRequestIfPending(at: 0, with: [systemTrack])
        await refresh.value

        XCTAssertEqual(sut.systemState, .loaded)
        XCTAssertEqual(sut.tracks, [systemTrack])
    }

    /// 用户确认删除后必须调用真实本地入口，并经同一个 requestReload 清掉所有共享页面的数据。
    @MainActor
    func testDeleteDownloadedTrackUsesSharedDeleteAndReloadEntry() async {
        let track = makeTrack(
            id: "delete-local",
            source: .downloaded(fileName: "delete-local.m4a")
        )
        let localStore = DeletingLocalMusicStore(tracks: [track])
        let sut = LibraryViewModel(
            library: StubMusicLibrary(tracks: []),
            localStore: localStore,
            deleteLocalTrack: { track in localStore.delete(track) }
        )
        await sut.requestReload()

        await sut.deleteDownloadedTrack(track)

        XCTAssertEqual(localStore.deletedIDs, [track.id])
        XCTAssertEqual(localStore.loadCount, 2)
        XCTAssertTrue(sut.tracks.isEmpty)
        XCTAssertEqual(sut.localState, .empty)
    }

    /// 如果新 reload 启动后任一旧来源的迟到事件仍能覆盖状态或列表，此测试应失败。
    @MainActor
    func testOlderReloadRejectsLateEventsFromBothSources() async {
        let newSystemTrack = makeTrack(id: "new-system")
        let newLocalTrack = makeTrack(
            id: "new-local",
            source: .downloaded(fileName: "new-local.m4a")
        )
        let library = DeferredMusicLibrary()
        let localStore = DeferredLocalMusicStore()
        let sut = LibraryViewModel(library: library, localStore: localStore)

        let older = Task { await sut.reload() }
        let oldSourcesStarted = await eventually {
            library.requestCount == 1 && localStore.requestCount == 1
        }
        XCTAssertTrue(oldSourcesStarted)

        let newer = Task { await sut.reload() }
        let bothGenerationsStarted = await eventually {
            library.requestCount == 2 && localStore.requestCount == 2
        }
        XCTAssertTrue(bothGenerationsStarted)
        guard bothGenerationsStarted else {
            await finishReloads(
                [older, newer],
                expectedRequests: 2,
                library: library,
                localStore: localStore
            )
            return
        }

        library.resumeRequest(at: 1, with: [newSystemTrack])
        localStore.resumeRequest(at: 1, with: [newLocalTrack])
        await newer.value
        XCTAssertEqual(sut.tracks, [newSystemTrack, newLocalTrack])
        XCTAssertEqual(sut.systemState, .loaded)
        XCTAssertEqual(sut.localState, .loaded)

        library.resumeRequest(at: 0, throwing: TestError.unavailable)
        localStore.resumeRequest(at: 0, throwing: TestError.unavailable)
        await older.value

        XCTAssertEqual(sut.tracks, [newSystemTrack, newLocalTrack])
        XCTAssertEqual(sut.systemState, .loaded)
        XCTAssertEqual(sut.localState, .loaded)
    }

    /// 如果正式系统查询仍占住 MainActor，本地 background context 的结果无法先发布。
    @MainActor
    func testProductionReloadPublishesLocalWhileSystemQueryIsBlocked() async throws {
        let systemGate = ProductionQueryGate()
        let systemProbe = ProductionThreadProbe()
        let localProbe = ProductionThreadProbe()
        let library = MusicLibraryService(
            authorizationStatusProvider: { .authorized },
            metadataQuery: {
                systemProbe.recordCurrentThread()
                systemGate.wait()
                return [Self.systemMetadata(id: 1)]
            }
        )
        let localStore = LocalMusicStore(
            container: try makeInMemoryContainer(),
            backgroundQuery: { _ in
                localProbe.recordCurrentThread()
                return [Self.localRecord(id: "local")]
            }
        )
        let sut = LibraryViewModel(library: library, localStore: localStore)
        defer { systemGate.open() }

        let reload = Task { await sut.reload() }
        let systemStarted = await eventually { systemProbe.hasRecordedThread }
        let localPublished = await eventually {
            sut.localState == .loaded && sut.tracks.map(\.id) == ["local"]
        }

        XCTAssertTrue(systemStarted)
        XCTAssertEqual(systemProbe.wasMainThread, false)
        XCTAssertEqual(localProbe.wasMainThread, false)
        XCTAssertTrue(localPublished)
        XCTAssertTrue(Thread.isMainThread)
        XCTAssertEqual(sut.systemState, .loading)

        systemGate.open()
        await reload.value
        XCTAssertEqual(sut.tracks.map(\.id), ["system-1", "local"])
    }

    /// 如果正式本地查询仍使用 viewContext.performAndWait，系统后台结果无法先发布。
    @MainActor
    func testProductionReloadPublishesSystemWhileLocalQueryIsBlocked() async throws {
        let localGate = ProductionQueryGate()
        let systemProbe = ProductionThreadProbe()
        let localProbe = ProductionThreadProbe()
        let library = MusicLibraryService(
            authorizationStatusProvider: { .authorized },
            metadataQuery: {
                systemProbe.recordCurrentThread()
                return [Self.systemMetadata(id: 2)]
            }
        )
        let localStore = LocalMusicStore(
            container: try makeInMemoryContainer(),
            backgroundQuery: { _ in
                localProbe.recordCurrentThread()
                localGate.wait()
                return [Self.localRecord(id: "local")]
            }
        )
        let sut = LibraryViewModel(library: library, localStore: localStore)
        defer { localGate.open() }

        let reload = Task { await sut.reload() }
        let localStarted = await eventually { localProbe.hasRecordedThread }
        let systemPublished = await eventually {
            sut.systemState == .loaded && sut.tracks.map(\.id) == ["system-2"]
        }

        XCTAssertTrue(localStarted)
        XCTAssertEqual(localProbe.wasMainThread, false)
        XCTAssertEqual(systemProbe.wasMainThread, false)
        XCTAssertTrue(systemPublished)
        XCTAssertTrue(Thread.isMainThread)
        XCTAssertEqual(sut.localState, .loading)

        localGate.open()
        await reload.value
        XCTAssertEqual(sut.tracks.map(\.id), ["system-2", "local"])
    }

    /// 即使旧正式查询不能物理取消，其后台迟到值也不能越过 generation 门禁。
    @MainActor
    func testProductionReloadRejectsOldBlockedSystemQuery() async throws {
        let sequence = ProductionSystemQuerySequence()
        let library = MusicLibraryService(
            authorizationStatusProvider: { .authorized },
            metadataQuery: { sequence.query() }
        )
        let localStore = LocalMusicStore(
            container: try makeInMemoryContainer(),
            backgroundQuery: { _ in [] }
        )
        let sut = LibraryViewModel(library: library, localStore: localStore)
        defer { sequence.releaseFirst() }

        let older = Task { await sut.reload() }
        let firstStarted = await eventually { sequence.queryCount >= 1 }
        XCTAssertTrue(firstStarted)

        let newer = Task { await sut.reload() }
        let newerPublished = await eventually {
            sequence.queryCount >= 2 && sut.tracks.map(\.id) == ["system-202"]
        }
        XCTAssertTrue(newerPublished)

        sequence.releaseFirst()
        await newer.value
        await older.value

        XCTAssertEqual(sut.tracks.map(\.id), ["system-202"])
        XCTAssertEqual(sut.systemState, .loaded)
        XCTAssertEqual(sut.localState, .empty)
    }

    /// 如果没有当前歌曲时仍显示演示内容，或真实歌曲元数据没有映射到界面，此测试应失败。
    @MainActor
    func testMiniPlayerHidesWithoutTrackAndShowsCurrentMetadata() async throws {
        let snapshots = CurrentValueSubject<PlaybackSnapshot, Never>(PlaybackSnapshot())
        let sut = MiniPlayerView(
            snapshotPublisher: snapshots.eraseToAnyPublisher(),
            onTogglePlay: {},
            onOpenPlayer: {}
        )
        XCTAssertTrue(sut.isHidden)

        let track = makeTrack(id: "current", title: "未完待续", artist: "陈粒")
        snapshots.send(PlaybackSnapshot(status: .paused, track: track))
        await waitUntil { !sut.isHidden }

        let title = try XCTUnwrap(findView(identifier: "mini.title", in: sut) as? UILabel)
        let artist = try XCTUnwrap(findView(identifier: "mini.artist", in: sut) as? UILabel)
        XCTAssertFalse(sut.isHidden)
        XCTAssertEqual(title.text, track.title)
        XCTAssertEqual(artist.text, track.artist)
    }

    /// 如果迷你播放器退回普通纯色卡片，关键悬浮层就失去材质层次。
    @MainActor
    func testMiniPlayerUsesMaterialInsideExistingAdaptiveCard() throws {
        let snapshots = CurrentValueSubject<PlaybackSnapshot, Never>(
            PlaybackSnapshot(status: .paused, track: makeTrack(id: "material"))
        )
        let sut = MiniPlayerView(
            snapshotPublisher: snapshots.eraseToAnyPublisher(),
            onTogglePlay: {},
            onOpenPlayer: {}
        )

        let material = try XCTUnwrap(
            findView(identifier: "mini.material", in: sut) as? UIVisualEffectView
        )

        XCTAssertTrue(material.effect is UIBlurEffect)
        XCTAssertEqual(sut.layer.cornerRadius, 14)
        XCTAssertTrue(sut.constraints.contains {
            $0.firstAttribute == .height && $0.relation == .greaterThanOrEqual && $0.constant == 64
        })
    }

    /// 如果迷你播放器仍使用系统符号，或界面样式变化后没有切换红白资源，此测试应失败。
    @MainActor
    func testMiniPlayerUsesAppearanceSpecificMusicNoteWhenArtworkIsMissing() async throws {
        let track = makeTrack(id: "mini-no-artwork")
        let snapshots = CurrentValueSubject<PlaybackSnapshot, Never>(
            PlaybackSnapshot(status: .paused, track: track)
        )
        let sut = MiniPlayerView(
            snapshotPublisher: snapshots.eraseToAnyPublisher(),
            onTogglePlay: {},
            onOpenPlayer: {}
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let host = UIViewController()
        window.rootViewController = host
        host.view.addSubview(sut)
        window.isHidden = false
        defer { window.isHidden = true }
        await waitUntil { !sut.isHidden }
        let artwork = try XCTUnwrap(
            findView(identifier: "mini.artwork", in: sut) as? UIImageView
        )

        sut.overrideUserInterfaceStyle = .light
        sut.layoutIfNeeded()
        let redImage = try XCTUnwrap(UIImage(named: "music-note-red"))
        XCTAssertEqual(artwork.image?.pngData(), redImage.pngData())
        XCTAssertEqual(artwork.contentMode, .center)

        sut.overrideUserInterfaceStyle = .dark
        sut.layoutIfNeeded()
        let whiteImage = try XCTUnwrap(UIImage(named: "music-note-white"))
        XCTAssertEqual(artwork.image?.pngData(), whiteImage.pngData())
        XCTAssertEqual(artwork.contentMode, .center)
    }

    /// 如果外观切换把歌曲真实封面替换为默认音符，此测试应失败。
    @MainActor
    func testMiniPlayerKeepsRealArtworkAcrossAppearanceChanges() async throws {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2))
        let artworkData = renderer.pngData { context in
            UIColor.systemBlue.setFill()
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
        let track = makeTrack(id: "mini-artwork", artworkData: artworkData)
        let snapshots = CurrentValueSubject<PlaybackSnapshot, Never>(
            PlaybackSnapshot(status: .paused, track: track)
        )
        let sut = MiniPlayerView(
            snapshotPublisher: snapshots.eraseToAnyPublisher(),
            onTogglePlay: {},
            onOpenPlayer: {}
        )
        await waitUntil { !sut.isHidden }
        let artwork = try XCTUnwrap(
            findView(identifier: "mini.artwork", in: sut) as? UIImageView
        )

        sut.overrideUserInterfaceStyle = .dark
        sut.layoutIfNeeded()

        XCTAssertEqual(artwork.image?.pngData(), UIImage(data: artworkData)?.pngData())
        XCTAssertEqual(artwork.contentMode, .scaleAspectFill)
    }

    /// 如果播放状态对应了错误的按钮语义，此测试应失败。
    @MainActor
    func testMiniPlayerUsesPauseOnlyWhilePlaying() async throws {
        let track = makeTrack(id: "current")
        let snapshots = CurrentValueSubject<PlaybackSnapshot, Never>(
            PlaybackSnapshot(status: .playing, track: track)
        )
        let sut = MiniPlayerView(
            snapshotPublisher: snapshots.eraseToAnyPublisher(),
            onTogglePlay: {},
            onOpenPlayer: {}
        )
        await waitUntil { !sut.isHidden }
        let toggle = try XCTUnwrap(findView(identifier: "mini.toggle", in: sut) as? UIButton)
        XCTAssertEqual(toggle.accessibilityLabel, L10n.text("common.pause"))

        snapshots.send(PlaybackSnapshot(status: .failed("失败"), track: track))
        await waitUntil { toggle.accessibilityLabel == L10n.text("common.play") }
        XCTAssertEqual(toggle.accessibilityLabel, L10n.text("common.play"))
    }

    /// 如果按钮和整行点击没有调用各自的上层动作，此测试应失败。
    @MainActor
    func testMiniPlayerRoutesToggleAndOpenActions() throws {
        let snapshots = CurrentValueSubject<PlaybackSnapshot, Never>(PlaybackSnapshot())
        var toggleCount = 0
        var openCount = 0
        let sut = MiniPlayerView(
            snapshotPublisher: snapshots.eraseToAnyPublisher(),
            onTogglePlay: { toggleCount += 1 },
            onOpenPlayer: { openCount += 1 }
        )
        let toggle = try XCTUnwrap(findView(identifier: "mini.toggle", in: sut) as? UIButton)
        let open = try XCTUnwrap(findView(identifier: "mini.open", in: sut) as? UIButton)

        XCTAssertEqual(open.accessibilityLabel, L10n.text("player.open_now_playing"))

        toggle.sendActions(for: .touchUpInside)
        open.sendActions(for: .touchUpInside)

        XCTAssertEqual(toggleCount, 1)
        XCTAssertEqual(openCount, 1)
    }

    /// 如果 stop 后订阅仍持续改写界面，此测试应失败。
    @MainActor
    func testMiniPlayerStopCancelsSnapshotUpdates() async {
        let track = makeTrack(id: "current")
        let snapshots = CurrentValueSubject<PlaybackSnapshot, Never>(
            PlaybackSnapshot(status: .paused, track: track)
        )
        let sut = MiniPlayerView(
            snapshotPublisher: snapshots.eraseToAnyPublisher(),
            onTogglePlay: {},
            onOpenPlayer: {}
        )
        await waitUntil { !sut.isHidden }

        sut.stop()
        snapshots.send(PlaybackSnapshot())
        await Task.yield()

        XCTAssertFalse(sut.isHidden)
    }

    /// 如果父容器只约束左右和底部时高度仍不确定，或辅助字号裁切文本，此测试应失败。
    @MainActor
    func testMiniPlayerHasUnambiguousAdaptiveHeightAtAccessibilitySize() async throws {
        let track = makeTrack(id: "current", title: "未完待续", artist: "陈粒")
        let snapshots = CurrentValueSubject<PlaybackSnapshot, Never>(
            PlaybackSnapshot(status: .paused, track: track)
        )
        let accessibilityTraits = UITraitCollection(
            preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge
        )
        var sut: MiniPlayerView!
        accessibilityTraits.performAsCurrent {
            sut = MiniPlayerView(
                snapshotPublisher: snapshots.eraseToAnyPublisher(),
                onTogglePlay: {},
                onOpenPlayer: {}
            )
        }

        let host = UIViewController()
        let child = UIViewController()
        host.loadViewIfNeeded()
        child.loadViewIfNeeded()
        host.view.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        host.addChild(child)
        host.view.addSubview(child.view)
        child.view.frame = host.view.bounds
        child.didMove(toParent: host)
        host.setOverrideTraitCollection(accessibilityTraits, forChild: child)

        sut.translatesAutoresizingMaskIntoConstraints = false
        child.view.addSubview(sut)
        NSLayoutConstraint.activate([
            sut.leadingAnchor.constraint(equalTo: child.view.safeAreaLayoutGuide.leadingAnchor, constant: 8),
            sut.trailingAnchor.constraint(equalTo: child.view.safeAreaLayoutGuide.trailingAnchor, constant: -8),
            sut.bottomAnchor.constraint(equalTo: child.view.safeAreaLayoutGuide.bottomAnchor, constant: -8)
        ])
        await waitUntil { !sut.isHidden }
        host.view.layoutIfNeeded()

        let title = try XCTUnwrap(findView(identifier: "mini.title", in: sut) as? UILabel)
        let artist = try XCTUnwrap(findView(identifier: "mini.artist", in: sut) as? UILabel)
        XCTAssertFalse(sut.hasAmbiguousLayout)
        XCTAssertGreaterThanOrEqual(sut.bounds.height, 64)
        XCTAssertGreaterThanOrEqual(sut.intrinsicContentSize.height, 64)
        XCTAssertGreaterThanOrEqual(title.bounds.height + 0.5, title.font.lineHeight)
        XCTAssertGreaterThanOrEqual(artist.bounds.height + 0.5, artist.font.lineHeight)
    }

    /// 如果搜索选择使用总列表的错误索引，或没有把筛选队列完整交给上层，此测试应失败。
    @MainActor
    func testSearchSelectionReturnsFilteredQueueAndMatchingIndex() async {
        let first = makeTrack(id: "first", title: "普通歌曲")
        let second = makeTrack(id: "second", title: "目标歌曲")
        let third = makeTrack(id: "third", album: "目标专辑")
        let viewModel = LibraryViewModel(
            library: StubMusicLibrary(tracks: [first, second, third]),
            localStore: StubLocalMusicStore(tracks: [])
        )
        await viewModel.reload()
        let sut = SearchViewController(viewModel: viewModel)
        var selectedQueue = [SimpleMusic.MusicTrack]()
        var selectedIndex: Int?
        sut.onSelectTrack = { queue, index in
            selectedQueue = queue
            selectedIndex = index
        }
        sut.loadViewIfNeeded()
        sut.searchController.searchBar.text = "目标"
        sut.updateSearchResults(for: sut.searchController)

        sut.collectionView(
            sut.collectionView,
            didSelectItemAt: IndexPath(item: 1, section: 0)
        )

        XCTAssertEqual(selectedQueue.map(\.id), [second.id, third.id])
        XCTAssertEqual(selectedIndex, 1)
    }

    /// 如果资料库首页仍写死中文标题、入口名称或辅助功能提示，此测试应失败。
    @MainActor
    func testLibraryHomeUsesLocalizedTitleCategoriesAndNavigationActions() async throws {
        let viewModel = LibraryViewModel(
            library: StubMusicLibrary(tracks: [makeTrack(id: "recent")]),
            localStore: StubLocalMusicStore(tracks: [])
        )
        await viewModel.reload()
        let library = LibraryViewController(viewModel: viewModel)
        let navigation = UINavigationController(rootViewController: library)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = navigation
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        navigation.view.layoutIfNeeded()
        let collection = try XCTUnwrap(
            allSubviews(in: library.view).compactMap { $0 as? UICollectionView }.first
        )

        XCTAssertEqual(library.title, L10n.text("library.title"))
        let navigationLabels = library.navigationItem.rightBarButtonItems?
            .compactMap { $0.customView?.accessibilityLabel } ?? []
        XCTAssertTrue(navigationLabels.contains(L10n.text("library.download_audio")))
        XCTAssertTrue(navigationLabels.contains(L10n.text("library.open_settings")))

        let categories: [(LibraryCategory, String)] = [
            (.songs, "category.songs"),
            (.albums, "category.albums"),
            (.artists, "category.artists"),
            (.downloaded, "category.downloaded")
        ]
        var categoryColors = [UIColor]()
        for (index, (_, expected)) in categories.enumerated() {
            let cell = try XCTUnwrap(collection.cellForItem(at: IndexPath(item: index, section: 0)))
            XCTAssertEqual(cell.accessibilityLabel, L10n.text(expected))
            categoryColors.append(try XCTUnwrap(cell.backgroundColor))
            XCTAssertEqual(cell.layer.cornerRadius, Theme.cardRadius)
            XCTAssertTrue(
                allSubviews(in: cell)
                    .compactMap { ($0 as? UILabel)?.text }
                    .contains(L10n.text(expected))
            )
        }
        let resolvedColors = categoryColors.map {
            $0.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        }
        XCTAssertEqual(Set(resolvedColors).count, categories.count)

        let header = library.collectionView(
            collection,
            viewForSupplementaryElementOfKind: UICollectionView.elementKindSectionHeader,
            at: IndexPath(item: 0, section: 1)
        )
        let headerText = try XCTUnwrap(
            allSubviews(in: header).compactMap { ($0 as? UILabel)?.text }.first
        )
        XCTAssertEqual(headerText, L10n.text("library.recently_added"))
    }

    /// 如果资料库来源错误或空资料库提示没有走资源键，此测试应失败。
    @MainActor
    func testLibraryStatusMessagesUseLocalizedResources() async throws {
        let systemErrorViewModel = LibraryViewModel(
            library: StubMusicLibrary(error: TestError.unavailable),
            localStore: StubLocalMusicStore(error: TestError.unavailable)
        )
        await systemErrorViewModel.reload()
        XCTAssertEqual(systemErrorViewModel.systemState, .failed(L10n.text("library.error.system")))
        XCTAssertEqual(systemErrorViewModel.localState, .failed(L10n.text("library.error.local")))

        let deletionViewModel = LibraryViewModel(
            library: StubMusicLibrary(tracks: []),
            localStore: StubLocalMusicStore(tracks: []),
            deleteLocalTrack: { _ in throw TestError.unavailable }
        )
        await deletionViewModel.deleteDownloadedTrack(
            makeTrack(id: "delete-error", source: .downloaded(fileName: "delete-error.m4a"))
        )
        XCTAssertEqual(
            deletionViewModel.localState,
            .failed(L10n.text("library.error.delete_local"))
        )

        let permissionViewModel = LibraryViewModel(
            library: StubMusicLibrary(
                tracks: [],
                authorizationStatus: .denied
            ),
            localStore: StubLocalMusicStore(tracks: [])
        )
        await permissionViewModel.reload()
        let library = LibraryViewController(viewModel: permissionViewModel)
        let navigation = UINavigationController(rootViewController: library)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = navigation
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        navigation.view.layoutIfNeeded()
        let collection = try XCTUnwrap(
            allSubviews(in: library.view).compactMap { $0 as? UICollectionView }.first
        )
        let notice = try XCTUnwrap(collection.cellForItem(at: IndexPath(item: 0, section: 0)))
        XCTAssertTrue(
            allSubviews(in: notice)
                .compactMap { ($0 as? UILabel)?.text }
                .contains(L10n.text("library.permission_required"))
        )
    }

    /// 如果真实资料库空状态单元格绕过资源键，此测试应失败。
    @MainActor
    func testLibraryEmptyStateUsesLocalizedMessage() async throws {
        let viewModel = LibraryViewModel(
            library: StubMusicLibrary(tracks: []),
            localStore: StubLocalMusicStore(tracks: [])
        )
        await viewModel.reload()
        let library = LibraryViewController(viewModel: viewModel)
        let navigation = UINavigationController(rootViewController: library)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = navigation
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        navigation.view.layoutIfNeeded()
        let collection = try XCTUnwrap(
            allSubviews(in: library.view).compactMap { $0 as? UICollectionView }.first
        )
        let emptyNotice = try XCTUnwrap(
            collection.cellForItem(at: IndexPath(item: 0, section: 0))
        )
        let emptyText = try XCTUnwrap(
            allSubviews(in: emptyNotice).compactMap { ($0 as? UILabel)?.text }.first
        )

        XCTAssertEqual(emptyText, L10n.text("library.empty"))
    }

    /// 如果任一资料库列表把标题或操作按钮固定为中文，此测试应失败。
    @MainActor
    func testTrackListsUseLocalizedCategoryTitlesAndActions() throws {
        let categories: [(LibraryCategory, String)] = [
            (.songs, "category.songs"),
            (.albums, "category.albums"),
            (.artists, "category.artists"),
            (.downloaded, "category.downloaded")
        ]

        for (category, key) in categories {
            let list = TrackListViewController(
                category: category,
                tracks: [makeTrack(id: key)],
                onPlay: { _, _ in }
            )
            list.loadViewIfNeeded()

            XCTAssertEqual(list.title, L10n.text(key))
            XCTAssertEqual(
                (try XCTUnwrap(findView(identifier: "list.playAll", in: list.view) as? UIButton))
                    .configuration?.title,
                L10n.text("list.play_all")
            )
            XCTAssertEqual(
                (try XCTUnwrap(findView(identifier: "list.shuffle", in: list.view) as? UIButton))
                    .configuration?.title,
                L10n.text("list.shuffle")
            )
            XCTAssertEqual(
                (try XCTUnwrap(findView(identifier: "list.sort", in: list.view) as? UIButton))
                    .configuration?.title,
                L10n.text("list.sort")
            )
        }
    }

    /// 如果分组歌曲数量或 VoiceOver 标签绕过 stringsdict/位置参数，此测试应失败。
    @MainActor
    func testTrackGroupCellUsesLocalizedPluralCountAndAccessibilityFormat() throws {
        let album = "Localized Album"
        let list = TrackListViewController(
            category: .albums,
            tracks: [
                makeTrack(id: "one", album: album),
                makeTrack(id: "two", album: album)
            ],
            onPlay: { _, _ in }
        )
        let navigation = UINavigationController(rootViewController: list)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = navigation
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        navigation.view.layoutIfNeeded()
        let collection = try XCTUnwrap(
            allSubviews(in: list.view).compactMap { $0 as? UICollectionView }.first
        )
        let cell = try XCTUnwrap(collection.cellForItem(at: IndexPath(item: 0, section: 0)))
        let countText = L10n.plural("tracks.count", count: 2)

        XCTAssertTrue(
            allSubviews(in: cell).compactMap { ($0 as? UILabel)?.text }.contains(countText)
        )
        XCTAssertEqual(
            cell.accessibilityLabel,
            L10n.format("track_group.accessibility", album, countText)
        )
    }

    /// 如果删除确认弹窗的标题、歌曲名消息或操作仍写死中文，此测试应失败。
    @MainActor
    func testLocalTrackDeletionPromptUsesLocalizedAlertContent() throws {
        let host = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let track = makeTrack(
            id: "delete-prompt",
            title: "A Local Song",
            source: .downloaded(fileName: "delete-prompt.m4a")
        )

        UIView.setAnimationsEnabled(false)
        defer { UIView.setAnimationsEnabled(true) }
        host.presentLocalTrackDeletionPrompt(for: track, onConfirm: {})

        let alert = try XCTUnwrap(host.presentedViewController as? UIAlertController)
        XCTAssertEqual(alert.title, L10n.text("deletion.title"))
        XCTAssertEqual(alert.message, L10n.format("deletion.message", track.title))
        XCTAssertEqual(alert.actions.map(\.title), [
            L10n.text("common.cancel"),
            L10n.text("common.delete")
        ])
    }

    /// 如果搜索标题、占位提示、空状态或其 VoiceOver 文案仍固定为中文，此测试应失败。
    @MainActor
    func testSearchUsesLocalizedTitlePlaceholderAndEmptyStates() async throws {
        let emptyViewModel = LibraryViewModel(
            library: StubMusicLibrary(tracks: []),
            localStore: StubLocalMusicStore(tracks: [])
        )
        let emptySearch = SearchViewController(viewModel: emptyViewModel)
        emptySearch.loadViewIfNeeded()
        let emptyLabel = try XCTUnwrap(findView(identifier: "search.empty", in: emptySearch.view) as? UILabel)

        XCTAssertEqual(emptySearch.title, L10n.text("search.title"))
        XCTAssertEqual(emptySearch.searchController.searchBar.placeholder, L10n.text("search.placeholder"))
        XCTAssertEqual(emptySearch.searchController.searchBar.accessibilityLabel, L10n.text("search.placeholder"))
        XCTAssertEqual(emptyLabel.text, L10n.text("search.empty_library"))

        let populatedViewModel = LibraryViewModel(
            library: StubMusicLibrary(tracks: [makeTrack(id: "searchable")]),
            localStore: StubLocalMusicStore(tracks: [])
        )
        await populatedViewModel.reload()
        let populatedSearch = SearchViewController(viewModel: populatedViewModel)
        populatedSearch.loadViewIfNeeded()
        populatedSearch.searchController.searchBar.text = "not found"
        populatedSearch.updateSearchResults(for: populatedSearch.searchController)
        let noResultsLabel = try XCTUnwrap(
            findView(identifier: "search.empty", in: populatedSearch.view) as? UILabel
        )
        XCTAssertEqual(noResultsLabel.text, L10n.text("search.no_results"))
    }

    /// 如果搜索空状态退回单独一行灰字，就会失去品牌图形和清晰的卡片层次。
    @MainActor
    func testSearchEmptyStateUsesBrandedArtworkCard() throws {
        let viewModel = LibraryViewModel(
            library: StubMusicLibrary(tracks: []),
            localStore: StubLocalMusicStore(tracks: [])
        )
        let sut = SearchViewController(viewModel: viewModel)
        sut.loadViewIfNeeded()

        let card = try XCTUnwrap(findView(identifier: "search.empty.visual", in: sut.view))
        let artwork = try XCTUnwrap(
            findView(identifier: "search.empty.artwork", in: card) as? UIImageView
        )
        let message = try XCTUnwrap(
            findView(identifier: "search.empty", in: card) as? UILabel
        )

        XCTAssertEqual(card.layer.cornerRadius, 18)
        XCTAssertNotNil(artwork.image)
        XCTAssertEqual(message.text, L10n.text("search.empty_library"))
        XCTAssertEqual(message.textAlignment, .center)
    }

    /// 如果手机资料库与搜索各自创建 ViewModel，此测试应失败。
    @MainActor
    func testMainTabsShareInjectedLibraryViewModel() throws {
        let viewModel = LibraryViewModel(
            library: StubMusicLibrary(tracks: []),
            localStore: StubLocalMusicStore(tracks: [])
        )
        let snapshots = CurrentValueSubject<PlaybackSnapshot, Never>(PlaybackSnapshot())
        let sut = MainTabBarController(
            libraryViewModel: viewModel,
            snapshotPublisher: snapshots.eraseToAnyPublisher(),
            onPlay: { _, _ in },
            onTogglePlay: {},
            onOpenPlayer: {}
        )
        sut.loadViewIfNeeded()

        let controllers = try XCTUnwrap(sut.viewControllers)
        let libraryNavigation = try XCTUnwrap(controllers[0] as? UINavigationController)
        let searchNavigation = try XCTUnwrap(controllers[1] as? UINavigationController)
        let library = try XCTUnwrap(libraryNavigation.viewControllers.first as? LibraryViewController)
        let search = try XCTUnwrap(searchNavigation.viewControllers.first as? SearchViewController)

        XCTAssertTrue(library.viewModel === viewModel)
        XCTAssertTrue(search.viewModel === viewModel)
        XCTAssertEqual(controllers[0].tabBarItem.title, L10n.text("tab.library"))
        XCTAssertEqual(controllers[1].tabBarItem.title, L10n.text("tab.search"))
    }

    /// 隐藏 Tab Bar 的普通页面仍需让迷你播放器悬浮在安全区底部，不能跟随 Tab Bar 临时 frame 跳动。
    @MainActor
    func testPhoneMiniPlayerStaysAtBottomWhenPushedPageHidesTabBar() async throws {
        let viewModel = LibraryViewModel(
            library: StubMusicLibrary(tracks: []),
            localStore: StubLocalMusicStore(tracks: [])
        )
        let snapshots = CurrentValueSubject<PlaybackSnapshot, Never>(
            PlaybackSnapshot(status: .paused, track: makeTrack(id: "navigation-mini"))
        )
        let sut = MainTabBarController(
            libraryViewModel: viewModel,
            snapshotPublisher: snapshots.eraseToAnyPublisher(),
            onPlay: { _, _ in },
            onTogglePlay: {},
            onOpenPlayer: {}
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = sut
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        await waitUntil {
            self.findView(identifier: "mini.material", in: sut.view)?.superview?.isHidden == false
        }
        sut.view.layoutIfNeeded()

        let miniPlayer = try XCTUnwrap(
            findView(identifier: "mini.material", in: sut.view)?.superview
        )
        let navigation = try XCTUnwrap(sut.selectedViewController as? UINavigationController)
        let pushed = UIViewController()
        pushed.hidesBottomBarWhenPushed = true

        navigation.pushViewController(pushed, animated: true)
        await waitUntil {
            navigation.topViewController === pushed
                && abs(
                    miniPlayer.frame.maxY
                        - (sut.view.safeAreaLayoutGuide.layoutFrame.maxY - 8)
                ) <= 1
        }
        sut.view.layoutIfNeeded()

        XCTAssertFalse(miniPlayer.isHidden)
        XCTAssertGreaterThan(miniPlayer.frame.minY, sut.view.bounds.midY)
        XCTAssertEqual(
            miniPlayer.frame.maxY,
            sut.view.safeAreaLayoutGuide.layoutFrame.maxY - 8,
            accuracy: 1
        )
        snapshots.send(
            PlaybackSnapshot(status: .playing, track: makeTrack(id: "navigation-mini-updated"))
        )
        await Task.yield()
        XCTAssertFalse(miniPlayer.isHidden)

        navigation.popViewController(animated: true)
        await waitUntil {
            navigation.topViewController !== pushed
                && abs(miniPlayer.frame.maxY - (sut.tabBar.frame.minY - 6)) <= 1
        }
        sut.view.layoutIfNeeded()

        XCTAssertFalse(miniPlayer.isHidden)
        XCTAssertGreaterThan(miniPlayer.frame.minY, sut.view.bounds.midY)
        XCTAssertEqual(miniPlayer.frame.maxY, sut.tabBar.frame.minY - 6, accuracy: 1)
    }

    /// UIKit 转场期间可能临时重挂载 Tab Bar；返回时不得激活跨层级约束而崩溃。
    @MainActor
    func testPhoneMiniPlayerReturnDoesNotDependOnTabBarHierarchy() async throws {
        let viewModel = LibraryViewModel(
            library: StubMusicLibrary(tracks: []),
            localStore: StubLocalMusicStore(tracks: [])
        )
        let snapshots = CurrentValueSubject<PlaybackSnapshot, Never>(
            PlaybackSnapshot(status: .paused, track: makeTrack(id: "hierarchy-mini"))
        )
        let sut = MainTabBarController(
            libraryViewModel: viewModel,
            snapshotPublisher: snapshots.eraseToAnyPublisher(),
            onPlay: { _, _ in },
            onTogglePlay: {},
            onOpenPlayer: {}
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = sut
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        await waitUntil {
            self.findView(identifier: "mini.material", in: sut.view)?.superview?.isHidden == false
        }

        let miniPlayer = try XCTUnwrap(
            findView(identifier: "mini.material", in: sut.view)?.superview
        )
        let navigation = try XCTUnwrap(sut.selectedViewController as? UINavigationController)
        let pushed = UIViewController()
        pushed.hidesBottomBarWhenPushed = true
        navigation.pushViewController(pushed, animated: false)

        // 复现真机返回转场中 Tab Bar 与根容器暂时没有共同层级的窗口。
        sut.tabBar.removeFromSuperview()
        navigation.popViewController(animated: false)
        sut.view.layoutIfNeeded()

        XCTAssertFalse(miniPlayer.isHidden)
        XCTAssertEqual(
            miniPlayer.frame.maxY,
            sut.view.bounds.maxY - sut.tabBar.bounds.height - 6,
            accuracy: 1
        )
    }

    /// 如果歌曲行偏离 46pt 封面、两行动态字体、下载标识或更多操作触控目标，此测试应失败。
    @MainActor
    func testTrackCellKeepsRequiredContentAndTouchTarget() throws {
        let cell = TrackCell(frame: CGRect(x: 0, y: 0, width: 360, height: 66))
        let track = makeTrack(
            id: "downloaded",
            title: "歌曲",
            artist: "艺人",
            album: "专辑",
            source: .downloaded(fileName: "song.m4a")
        )
        cell.configure(with: track)
        cell.layoutIfNeeded()

        let artwork = try XCTUnwrap(findView(identifier: "track.artwork", in: cell))
        let title = try XCTUnwrap(findView(identifier: "track.title", in: cell) as? UILabel)
        let subtitle = try XCTUnwrap(findView(identifier: "track.subtitle", in: cell) as? UILabel)
        let badge = try XCTUnwrap(findView(identifier: "track.downloaded", in: cell))
        let more = try XCTUnwrap(findView(identifier: "track.more", in: cell) as? UIButton)

        XCTAssertTrue(artwork.constraints.contains { $0.firstAttribute == .width && $0.constant == 46 })
        XCTAssertTrue(artwork.constraints.contains { $0.firstAttribute == .height && $0.constant == 46 })
        XCTAssertTrue(title.adjustsFontForContentSizeCategory)
        XCTAssertTrue(subtitle.adjustsFontForContentSizeCategory)
        XCTAssertFalse(badge.isHidden)
        XCTAssertEqual((badge as? UILabel)?.text, L10n.text("track.downloaded"))
        XCTAssertEqual(more.accessibilityLabel, L10n.text("track.more_actions"))
        XCTAssertTrue(more.constraints.contains {
            $0.firstAttribute == .width && $0.relation == .greaterThanOrEqual && $0.constant >= 44
        })
    }

    /// 关闭时，不展示。
    @MainActor
    func testDownloadCapabilityCanHideLibraryDownloadSurfaces() async throws {
        let downloaded = makeTrack(
            id: "hidden-download",
            source: .downloaded(fileName: "hidden-download.m4a")
        )
        let viewModel = LibraryViewModel(
            library: StubMusicLibrary(tracks: []),
            localStore: StubLocalMusicStore(tracks: [downloaded])
        )
        await viewModel.reload()
        let library = LibraryViewController(
            viewModel: viewModel,
            downloadFeatureEnabled: false
        )
        library.loadViewIfNeeded()

        let labels = library.navigationItem.rightBarButtonItems?
            .compactMap { $0.customView?.accessibilityLabel } ?? []
        XCTAssertFalse(labels.contains(L10n.text("library.download_audio")))

        let cell = TrackCell(frame: CGRect(x: 0, y: 0, width: 360, height: 66))
        cell.configure(with: downloaded, showsDownloadStatus: false)
        cell.layoutIfNeeded()
        let badge = try XCTUnwrap(findView(identifier: "track.downloaded", in: cell))
        let more = try XCTUnwrap(findView(identifier: "track.more", in: cell))
        XCTAssertTrue(badge.isHidden)
        XCTAssertTrue(more.isHidden)
    }

    /// 如果歌曲行 VoiceOver 文案继续硬编码中文标点，英文运行将不会读出语言对应的分隔。
    @MainActor
    func testTrackCellUsesActiveLanguageAccessibilityFormat() throws {
        let expectedByLanguage = [
            "en": "Title, Artist, Album",
            "zh-Hans": "Title，Artist，Album",
            "zh-Hant": "Title，Artist，Album",
        ]
        let activeLanguage = Bundle.main.preferredLocalizations.first ?? "en"
        let cell = TrackCell(frame: CGRect(x: 0, y: 0, width: 360, height: 66))
        cell.configure(with: makeTrack(
            id: "accessible-track",
            title: "Title",
            artist: "Artist",
            album: "Album"
        ))

        XCTAssertEqual(cell.accessibilityLabel, try XCTUnwrap(expectedByLanguage[activeLanguage]))
    }

    /// 如果系统歌曲仍沿用“仅本地歌曲显示更多”的旧分支，用户无法进入播放列表选择页。
    @MainActor
    func testTrackCellShowsMoreActionForSystemTrackWhenHandlerIsAvailable() throws {
        let cell = TrackCell(frame: CGRect(x: 0, y: 0, width: 360, height: 66))
        cell.configure(with: makeTrack(id: "system", source: .system(persistentID: 7)))
        cell.onMore = {}

        let more = try XCTUnwrap(findView(identifier: "track.more", in: cell))
        XCTAssertFalse(more.isHidden)
    }

    /// 如果无封面歌曲仍显示系统符号，或深浅色模式选错资源，此测试应失败。
    @MainActor
    func testTrackCellUsesAppearanceSpecificMusicNoteWhenArtworkIsMissing() throws {
        let cell = TrackCell(frame: CGRect(x: 0, y: 0, width: 360, height: 66))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let host = UIViewController()
        window.rootViewController = host
        host.view.addSubview(cell)
        window.isHidden = false
        defer { window.isHidden = true }
        let artwork = try XCTUnwrap(
            findView(identifier: "track.artwork", in: cell) as? UIImageView
        )

        cell.overrideUserInterfaceStyle = .light
        cell.configure(with: makeTrack(id: "no-artwork"))
        let redImage = try XCTUnwrap(UIImage(named: "music-note-red"))
        XCTAssertEqual(artwork.image?.pngData(), redImage.pngData())
        XCTAssertEqual(artwork.contentMode, .center)

        cell.overrideUserInterfaceStyle = .dark
        cell.layoutIfNeeded()
        let whiteImage = try XCTUnwrap(UIImage(named: "music-note-white"))
        XCTAssertEqual(artwork.image?.pngData(), whiteImage.pngData())
        XCTAssertEqual(artwork.contentMode, .center)
    }

    /// 如果切换外观时默认图逻辑覆盖了歌曲真实封面，此测试应失败。
    @MainActor
    func testTrackCellKeepsRealArtworkAcrossAppearanceChanges() throws {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2))
        let artworkData = renderer.pngData { context in
            UIColor.systemBlue.setFill()
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
        let cell = TrackCell(frame: CGRect(x: 0, y: 0, width: 360, height: 66))
        let artwork = try XCTUnwrap(
            findView(identifier: "track.artwork", in: cell) as? UIImageView
        )

        cell.overrideUserInterfaceStyle = .light
        cell.configure(with: makeTrack(id: "with-artwork", artworkData: artworkData))
        cell.overrideUserInterfaceStyle = .dark
        cell.layoutIfNeeded()

        XCTAssertEqual(artwork.image?.pngData(), UIImage(data: artworkData)?.pngData())
        XCTAssertEqual(artwork.contentMode, .scaleAspectFill)
    }

    /// 分类卡必须进入真实列表，且未实现的“最近播放”静态承诺不能占据一个 section。
    @MainActor
    func testLibraryCategoryCardPushesTrackListAndRemovesStaticRecentlyPlayed() throws {
        let viewModel = LibraryViewModel(
            library: StubMusicLibrary(tracks: []),
            localStore: StubLocalMusicStore(tracks: [])
        )
        let library = LibraryViewController(viewModel: viewModel)
        let navigation = UINavigationController(rootViewController: library)
        navigation.loadViewIfNeeded()
        library.loadViewIfNeeded()
        let collection = try XCTUnwrap(
            allSubviews(in: library.view).compactMap { $0 as? UICollectionView }.first
        )

        XCTAssertEqual(library.numberOfSections(in: collection), 2)
        library.collectionView(collection, didSelectItemAt: IndexPath(item: 0, section: 0))
        XCTAssertFalse(navigation.topViewController === library)
        XCTAssertEqual(navigation.topViewController?.title, L10n.text("category.songs"))
    }

    /// 如果第五个资料库入口没有把应用级共享 ViewModel 传给列表页，此测试应失败。
    @MainActor
    func testLibraryPlaylistCategoryPushesPlaylistListUsingSharedViewModel() throws {
        let libraryViewModel = LibraryViewModel(
            library: StubMusicLibrary(tracks: []),
            localStore: StubLocalMusicStore(tracks: [])
        )
        let playlistViewModel = try PlaylistViewModel(
            store: PlaylistStore.inMemory(),
            library: libraryViewModel
        )
        let library = LibraryViewController(
            viewModel: libraryViewModel,
            playlistViewModel: playlistViewModel
        )
        let navigation = UINavigationController(rootViewController: library)
        navigation.loadViewIfNeeded()
        library.loadViewIfNeeded()

        selectCategory(named: L10n.text("playlist.title"), in: library)

        let list = try XCTUnwrap(navigation.topViewController as? PlaylistListViewController)
        XCTAssertTrue(list.viewModel === playlistViewModel)
    }

    /// 如果资料库分类页没有继续传递共享播放列表状态，分类歌曲的更多菜单将无法加入播放列表。
    @MainActor
    func testLibraryTrackCategoryPassesSharedPlaylistViewModelToTrackList() throws {
        let libraryViewModel = LibraryViewModel(
            library: StubMusicLibrary(tracks: []),
            localStore: StubLocalMusicStore(tracks: [])
        )
        let playlistViewModel = try PlaylistViewModel(
            store: PlaylistStore.inMemory(),
            library: libraryViewModel
        )
        let library = LibraryViewController(
            viewModel: libraryViewModel,
            playlistViewModel: playlistViewModel
        )
        let navigation = UINavigationController(rootViewController: library)
        navigation.loadViewIfNeeded()
        library.loadViewIfNeeded()

        selectCategory(named: L10n.text("category.songs"), in: library)

        let list = try XCTUnwrap(navigation.topViewController as? TrackListViewController)
        XCTAssertTrue(list.playlistViewModel === playlistViewModel)
    }

    /// 如果系统歌曲更多操作没有展示选择页，或选择后传错歌曲/列表 ID，真实持久层不会得到该歌曲。
    @MainActor
    func testSystemTrackMoreActionPresentsPlaylistSelectionAndAddsTrack() async throws {
        let track = makeTrack(id: "system-1", source: .system(persistentID: 1))
        let libraryViewModel = LibraryViewModel(
            library: StubMusicLibrary(tracks: [track]),
            localStore: StubLocalMusicStore(tracks: [])
        )
        await libraryViewModel.reload()
        let store = try PlaylistStore.inMemory()
        let playlist = try store.create(name: "Favorites")
        let playlistViewModel = try PlaylistViewModel(store: store, library: libraryViewModel)
        let sut = SearchViewController(
            viewModel: libraryViewModel,
            playlistViewModel: playlistViewModel
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = sut
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        sut.loadViewIfNeeded()
        sut.view.layoutIfNeeded()
        sut.collectionView.reloadData()
        sut.collectionView.layoutIfNeeded()

        let cell = try XCTUnwrap(
            sut.collectionView.cellForItem(at: IndexPath(item: 0, section: 0)) as? TrackCell
        )
        try XCTUnwrap(findView(identifier: "track.more", in: cell) as? UIButton)
            .sendActions(for: .touchUpInside)
        let selection = try XCTUnwrap(
            sut.presentedViewController as? PlaylistSelectionViewController
        )

        selection.select(playlistID: playlist.id)

        XCTAssertEqual(try store.tracks(in: playlist.id), [track.id])
    }

    /// 如果本地歌曲“加入播放列表”action 没有连到选择页，实际点击后不会持久化准确歌曲。
    @MainActor
    func testLocalTrackMoreAddActionPresentsSelectionAndPersistsExactTrack() async throws {
        let track = makeTrack(
            id: "local-1",
            source: .downloaded(fileName: "local-1.m4a")
        )
        let libraryViewModel = LibraryViewModel(
            library: StubMusicLibrary(tracks: []),
            localStore: StubLocalMusicStore(tracks: [track])
        )
        await libraryViewModel.reload()
        let store = try PlaylistStore.inMemory()
        let playlist = try store.create(name: "Local Favorites")
        let playlistViewModel = try PlaylistViewModel(store: store, library: libraryViewModel)
        let sut = SearchViewController(
            viewModel: libraryViewModel,
            playlistViewModel: playlistViewModel
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = sut
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        sut.loadViewIfNeeded()
        sut.view.layoutIfNeeded()
        sut.collectionView.reloadData()
        sut.collectionView.layoutIfNeeded()

        let cell = try XCTUnwrap(
            sut.collectionView.cellForItem(at: IndexPath(item: 0, section: 0)) as? TrackCell
        )
        try XCTUnwrap(findView(identifier: "track.more", in: cell) as? UIButton)
            .sendActions(for: .touchUpInside)
        let actions = try XCTUnwrap(sut.presentedViewController as? UIAlertController)

        XCTAssertEqual(
            Set(actions.actions.compactMap(\.title)),
            Set([
                L10n.text("playlist.add"),
                L10n.text("deletion.action"),
                L10n.text("common.cancel"),
            ])
        )
        XCTAssertTrue(activateAlertAction(named: L10n.text("playlist.add"), in: actions))
        let didPresentSelection = await eventually {
            sut.presentedViewController is PlaylistSelectionViewController
        }
        XCTAssertTrue(didPresentSelection)
        let selection = try XCTUnwrap(
            sut.presentedViewController as? PlaylistSelectionViewController
        )

        selection.select(playlistID: playlist.id)

        XCTAssertEqual(try store.tracks(in: playlist.id), [track.id])
    }

    /// 如果本地歌曲删除 action 没有继续经过确认弹窗，或回调传错歌曲，此测试应失败。
    @MainActor
    func testLocalTrackMoreDeleteActionConfirmsAndForwardsExactTrack() async throws {
        let track = makeTrack(
            id: "local-delete-1",
            source: .downloaded(fileName: "local-delete-1.m4a")
        )
        let libraryViewModel = LibraryViewModel(
            library: StubMusicLibrary(tracks: []),
            localStore: StubLocalMusicStore(tracks: [track])
        )
        await libraryViewModel.reload()
        let playlistViewModel = try PlaylistViewModel(
            store: PlaylistStore.inMemory(),
            library: libraryViewModel
        )
        let sut = SearchViewController(
            viewModel: libraryViewModel,
            playlistViewModel: playlistViewModel
        )
        var deletedTrack: SimpleMusic.MusicTrack?
        sut.onDeleteTrack = { deletedTrack = $0 }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = sut
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        sut.loadViewIfNeeded()
        sut.view.layoutIfNeeded()
        sut.collectionView.reloadData()
        sut.collectionView.layoutIfNeeded()

        let cell = try XCTUnwrap(
            sut.collectionView.cellForItem(at: IndexPath(item: 0, section: 0)) as? TrackCell
        )
        try XCTUnwrap(findView(identifier: "track.more", in: cell) as? UIButton)
            .sendActions(for: .touchUpInside)
        let actions = try XCTUnwrap(sut.presentedViewController as? UIAlertController)
        XCTAssertTrue(activateAlertAction(named: L10n.text("deletion.action"), in: actions))
        let didPresentConfirmation = await eventually {
            (sut.presentedViewController as? UIAlertController)?.title == L10n.text("deletion.title")
        }
        XCTAssertTrue(didPresentConfirmation)
        let confirmation = try XCTUnwrap(sut.presentedViewController as? UIAlertController)

        XCTAssertTrue(activateAlertAction(named: L10n.text("common.delete"), in: confirmation))
        let didDelete = await eventually { deletedTrack != nil }
        XCTAssertTrue(didDelete)
        XCTAssertEqual(deletedTrack, track)
    }

    /// 如果空选择页只能返回列表目录而不能现场新建，新建后歌曲不会在同一操作中加入。
    @MainActor
    func testEmptyPlaylistSelectionCreatesPlaylistAndAddsTrack() throws {
        let track = makeTrack(id: "new-playlist-track")
        let libraryViewModel = LibraryViewModel(
            library: StubMusicLibrary(tracks: [track]),
            localStore: StubLocalMusicStore(tracks: [])
        )
        let store = try PlaylistStore.inMemory()
        let playlistViewModel = try PlaylistViewModel(store: store, library: libraryViewModel)
        let sut = PlaylistSelectionViewController(track: track, viewModel: playlistViewModel)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = sut
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        sut.loadViewIfNeeded()

        try XCTUnwrap(
            findView(identifier: "playlist.selection.new", in: sut.view) as? UIButton
        ).sendActions(for: .touchUpInside)
        let prompt = try XCTUnwrap(sut.presentedViewController as? UIAlertController)
        let nameField = try XCTUnwrap(prompt.textFields?.first)
        nameField.text = "Morning"
        nameField.sendActions(for: .editingDidEndOnExit)

        let playlist = try XCTUnwrap(store.fetchPlaylists().first)
        XCTAssertEqual(playlist.name, "Morning")
        XCTAssertEqual(try store.tracks(in: playlist.id), [track.id])
    }

    /// 如果新建按钮没有展示文本输入，或确认后没有经过真实 ViewModel 持久化，此测试应失败。
    @MainActor
    func testPlaylistListCreatesPlaylistFromAlertTextField() throws {
        let libraryViewModel = LibraryViewModel(
            library: StubMusicLibrary(tracks: []),
            localStore: StubLocalMusicStore(tracks: [])
        )
        let playlistViewModel = try PlaylistViewModel(
            store: PlaylistStore.inMemory(),
            library: libraryViewModel
        )
        let sut = PlaylistListViewController(viewModel: playlistViewModel, onPlay: { _, _ in })
        let navigation = UINavigationController(rootViewController: sut)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = navigation
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        navigation.view.layoutIfNeeded()

        let createButton = try XCTUnwrap(
            sut.navigationItem.rightBarButtonItem?.customView as? UIButton
        )
        XCTAssertEqual(createButton.accessibilityIdentifier, "playlist.new")
        createButton.sendActions(for: .touchUpInside)
        let alert = try XCTUnwrap(sut.presentedViewController as? UIAlertController)
        let textField = try XCTUnwrap(alert.textFields?.first)
        textField.text = "  Road Trip  "
        textField.sendActions(for: .editingDidEndOnExit)

        XCTAssertEqual(playlistViewModel.playlists.map(\.name), ["Road Trip"])
    }

    /// 如果列表数量没有来自持久化 trackIDs，或点行时没有按当前资料库解析歌曲，此测试应失败。
    @MainActor
    func testPlaylistListShowsTrackCountAndPushesResolvedTracks() async throws {
        let first = makeTrack(id: "playlist-first")
        let second = makeTrack(id: "playlist-second")
        let libraryViewModel = LibraryViewModel(
            library: StubMusicLibrary(tracks: [first, second]),
            localStore: StubLocalMusicStore(tracks: [])
        )
        await libraryViewModel.reload()
        let store = try PlaylistStore.inMemory()
        let playlist = try store.create(name: "Road Trip")
        try store.add(trackID: first.id, to: playlist.id)
        try store.add(trackID: second.id, to: playlist.id)
        let playlistViewModel = try PlaylistViewModel(store: store, library: libraryViewModel)
        let sut = PlaylistListViewController(viewModel: playlistViewModel, onPlay: { _, _ in })
        let navigation = UINavigationController(rootViewController: sut)
        navigation.loadViewIfNeeded()
        sut.loadViewIfNeeded()
        let table = try XCTUnwrap(
            allSubviews(in: sut.view).compactMap { $0 as? UITableView }.first
        )
        let cell = sut.tableView(table, cellForRowAt: IndexPath(row: 0, section: 0))
        let rowActions = try XCTUnwrap(
            sut.tableView(
                table,
                trailingSwipeActionsConfigurationForRowAt: IndexPath(row: 0, section: 0)
            )
        )

        XCTAssertEqual(cell.textLabel?.text, "Road Trip")
        XCTAssertEqual(cell.detailTextLabel?.text, L10n.plural("tracks.count", count: 2))
        XCTAssertEqual(rowActions.actions.count, 2)
        XCTAssertTrue(rowActions.actions.contains { $0.style == .destructive })
        sut.tableView(table, didSelectRowAt: IndexPath(row: 0, section: 0))
        let tracks = try XCTUnwrap(navigation.topViewController as? PlaylistTracksViewController)
        XCTAssertEqual(tracks.tracks.map(\.id), [first.id, second.id])
    }

    /// 如果空播放列表仍允许触发播放，或没有给出空状态，此测试应失败。
    @MainActor
    func testPlaylistTracksEmptyStateDisablesPlaybackActions() throws {
        let libraryViewModel = LibraryViewModel(
            library: StubMusicLibrary(tracks: []),
            localStore: StubLocalMusicStore(tracks: [])
        )
        let store = try PlaylistStore.inMemory()
        let playlist = try store.create(name: "Empty")
        let playlistViewModel = try PlaylistViewModel(store: store, library: libraryViewModel)
        var playbackCount = 0
        let sut = PlaylistTracksViewController(
            playlistID: playlist.id,
            viewModel: playlistViewModel,
            onPlay: { _, _ in playbackCount += 1 }
        )
        sut.loadViewIfNeeded()
        let empty = try XCTUnwrap(
            findView(identifier: "playlist.empty", in: sut.view) as? UILabel
        )
        let playAll = try XCTUnwrap(
            findView(identifier: "playlist.playAll", in: sut.view) as? UIButton
        )
        let shuffle = try XCTUnwrap(
            findView(identifier: "playlist.shuffle", in: sut.view) as? UIButton
        )

        XCTAssertFalse(empty.isHidden)
        XCTAssertFalse(playAll.isEnabled)
        XCTAssertFalse(shuffle.isEnabled)
        playAll.sendActions(for: .touchUpInside)
        shuffle.sendActions(for: .touchUpInside)
        XCTAssertEqual(playbackCount, 0)
    }

    /// 如果播放列表详情绕开现有播放 closure、改变索引或漏掉当前队列，此测试应失败。
    @MainActor
    func testPlaylistTracksPlayAllAndShuffleForwardExistingPlaybackClosure() async throws {
        let first = makeTrack(id: "queue-first")
        let second = makeTrack(id: "queue-second")
        let libraryViewModel = LibraryViewModel(
            library: StubMusicLibrary(tracks: [first, second]),
            localStore: StubLocalMusicStore(tracks: [])
        )
        await libraryViewModel.reload()
        let store = try PlaylistStore.inMemory()
        let playlist = try store.create(name: "Queue")
        try store.add(trackID: first.id, to: playlist.id)
        try store.add(trackID: second.id, to: playlist.id)
        let playlistViewModel = try PlaylistViewModel(store: store, library: libraryViewModel)
        var played = [([SimpleMusic.MusicTrack], Int)]()
        let sut = PlaylistTracksViewController(
            playlistID: playlist.id,
            viewModel: playlistViewModel,
            onPlay: { played.append(($0, $1)) }
        )
        sut.loadViewIfNeeded()

        try XCTUnwrap(findView(identifier: "playlist.playAll", in: sut.view) as? UIButton)
            .sendActions(for: .touchUpInside)
        try XCTUnwrap(findView(identifier: "playlist.shuffle", in: sut.view) as? UIButton)
            .sendActions(for: .touchUpInside)

        XCTAssertEqual(played.count, 2)
        XCTAssertEqual(played[0].0.map(\.id), [first.id, second.id])
        XCTAssertEqual(played[0].1, 0)
        XCTAssertEqual(Set(played[1].0.map(\.id)), Set([first.id, second.id]))
        XCTAssertEqual(played[1].1, 0)
    }

    /// 如果点第三首时详情页改传固定索引或重排队列，此测试应失败。
    @MainActor
    func testPlaylistTracksSelectionForwardsOrderedQueueAndSelectedIndex() async throws {
        let first = makeTrack(id: "selection-first")
        let second = makeTrack(id: "selection-second")
        let third = makeTrack(id: "selection-third")
        let libraryViewModel = LibraryViewModel(
            library: StubMusicLibrary(tracks: [first, second, third]),
            localStore: StubLocalMusicStore(tracks: [])
        )
        await libraryViewModel.reload()
        let store = try PlaylistStore.inMemory()
        let playlist = try store.create(name: "Selection")
        try store.add(trackID: first.id, to: playlist.id)
        try store.add(trackID: second.id, to: playlist.id)
        try store.add(trackID: third.id, to: playlist.id)
        let playlistViewModel = try PlaylistViewModel(store: store, library: libraryViewModel)
        var selectedQueue = [SimpleMusic.MusicTrack]()
        var selectedIndex: Int?
        let sut = PlaylistTracksViewController(
            playlistID: playlist.id,
            viewModel: playlistViewModel,
            onPlay: { queue, index in
                selectedQueue = queue
                selectedIndex = index
            }
        )
        sut.loadViewIfNeeded()
        let collection = try XCTUnwrap(
            allSubviews(in: sut.view).compactMap { $0 as? UICollectionView }.first
        )

        sut.collectionView(collection, didSelectItemAt: IndexPath(item: 2, section: 0))

        XCTAssertEqual(selectedQueue.map(\.id), [first.id, second.id, third.id])
        XCTAssertEqual(selectedIndex, 2)
    }

    /// 如果目录和详情只监听持久化列表，分阶段来源发布不会刷新已打开页面。
    @MainActor
    func testOpenPlaylistPagesRefreshForEachStagedLibraryPublication() async throws {
        let systemTrack = makeTrack(id: "system-801", title: "系统新结果")
        let localTrack = makeTrack(
            id: "00000000-0000-0000-0000-000000000802",
            title: "本地新结果",
            source: .downloaded(fileName: "local-802.m4a")
        )
        let systemLibrary = DeferredMusicLibrary()
        let localStore = DeferredLocalMusicStore()
        let libraryViewModel = LibraryViewModel(
            library: systemLibrary,
            localStore: localStore
        )
        let store = try PlaylistStore.inMemory()
        let playlist = try store.create(name: "分阶段")
        try store.add(trackID: systemTrack.id, to: playlist.id)
        try store.add(trackID: localTrack.id, to: playlist.id)
        let playlistViewModel = try PlaylistViewModel(
            store: store,
            library: libraryViewModel
        )
        let list = PlaylistListViewController(viewModel: playlistViewModel, onPlay: nil)
        let detail = PlaylistTracksViewController(
            playlistID: playlist.id,
            viewModel: playlistViewModel,
            onPlay: nil
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UINavigationController(rootViewController: list)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        list.loadViewIfNeeded()
        detail.loadViewIfNeeded()
        window.layoutIfNeeded()
        let table = try XCTUnwrap(
            allSubviews(in: list.view).compactMap { $0 as? UITableView }.first
        )

        XCTAssertEqual(
            table.cellForRow(at: IndexPath(row: 0, section: 0))?.detailTextLabel?.text,
            L10n.plural("tracks.count", count: 0)
        )
        XCTAssertTrue(detail.tracks.isEmpty)

        let firstReload = Task { await libraryViewModel.reload() }
        let firstSourcesStarted = await eventually {
            systemLibrary.requestCount == 1 && localStore.requestCount == 1
        }
        XCTAssertTrue(firstSourcesStarted)
        systemLibrary.resumeRequestIfPending(at: 0, with: [systemTrack])
        let systemStagePublished = await eventually {
            detail.tracks == [systemTrack]
                && table.cellForRow(at: IndexPath(row: 0, section: 0))?
                    .detailTextLabel?.text == L10n.plural("tracks.count", count: 1)
        }
        XCTAssertTrue(systemStagePublished)
        XCTAssertEqual(try store.tracks(in: playlist.id), [systemTrack.id, localTrack.id])

        localStore.resumeRequestIfPending(at: 0, with: [localTrack])
        await firstReload.value
        XCTAssertEqual(detail.tracks, [systemTrack, localTrack])
        XCTAssertEqual(
            table.cellForRow(at: IndexPath(row: 0, section: 0))?.detailTextLabel?.text,
            L10n.plural("tracks.count", count: 2)
        )

        let secondReload = Task { await libraryViewModel.reload() }
        let secondSourcesStarted = await eventually {
            systemLibrary.requestCount == 2 && localStore.requestCount == 2
        }
        XCTAssertTrue(secondSourcesStarted)
        systemLibrary.resumeRequestIfPending(at: 1, with: [])
        let systemRemovalPublished = await eventually {
            detail.tracks == [localTrack]
                && table.cellForRow(at: IndexPath(row: 0, section: 0))?
                    .detailTextLabel?.text == L10n.plural("tracks.count", count: 1)
        }
        XCTAssertTrue(systemRemovalPublished)
        XCTAssertEqual(try store.tracks(in: playlist.id), [systemTrack.id, localTrack.id])

        localStore.resumeRequestIfPending(at: 1, with: [])
        await secondReload.value
        XCTAssertTrue(detail.tracks.isEmpty)
        XCTAssertEqual(
            table.cellForRow(at: IndexPath(row: 0, section: 0))?.detailTextLabel?.text,
            L10n.plural("tracks.count", count: 0)
        )
        XCTAssertTrue(try store.tracks(in: playlist.id).isEmpty)
    }

    /// 如果同 ID 更新被去重或详情继续用旧快照，行元数据和三个播放入口都会保持旧值。
    @MainActor
    func testPlaylistDetailRedrawsAndPlaysLatestMetadataForSameTrackID() async throws {
        let oldTrack = makeTrack(id: "system-811", title: "旧标题", artist: "旧艺人")
        let updatedTrack = makeTrack(id: oldTrack.id, title: "新标题", artist: "新艺人")
        let systemLibrary = DeferredMusicLibrary()
        let libraryViewModel = LibraryViewModel(
            library: systemLibrary,
            localStore: StubLocalMusicStore(tracks: [])
        )
        let initialReload = Task { await libraryViewModel.reload() }
        let initialRequestStarted = await eventually { systemLibrary.requestCount == 1 }
        XCTAssertTrue(initialRequestStarted)
        systemLibrary.resumeRequestIfPending(at: 0, with: [oldTrack])
        await initialReload.value

        let store = try PlaylistStore.inMemory()
        let playlist = try store.create(name: "元数据")
        try store.add(trackID: oldTrack.id, to: playlist.id)
        let playlistViewModel = try PlaylistViewModel(
            store: store,
            library: libraryViewModel
        )
        var playedQueues = [[SimpleMusic.MusicTrack]]()
        let sut = PlaylistTracksViewController(
            playlistID: playlist.id,
            viewModel: playlistViewModel,
            onPlay: { queue, _ in playedQueues.append(queue) }
        )
        sut.loadViewIfNeeded()
        let collection = try XCTUnwrap(
            allSubviews(in: sut.view).compactMap { $0 as? UICollectionView }.first
        )

        let refresh = Task { await libraryViewModel.reload() }
        let refreshStarted = await eventually { systemLibrary.requestCount == 2 }
        XCTAssertTrue(refreshStarted)
        systemLibrary.resumeRequestIfPending(at: 1, with: [updatedTrack])
        await refresh.value

        let cell = sut.collectionView(
            collection,
            cellForItemAt: IndexPath(item: 0, section: 0)
        )
        let title = try XCTUnwrap(findView(identifier: "track.title", in: cell) as? UILabel)
        sut.collectionView(collection, didSelectItemAt: IndexPath(item: 0, section: 0))
        try XCTUnwrap(findView(identifier: "playlist.playAll", in: sut.view) as? UIButton)
            .sendActions(for: .touchUpInside)
        try XCTUnwrap(findView(identifier: "playlist.shuffle", in: sut.view) as? UIButton)
            .sendActions(for: .touchUpInside)

        XCTAssertEqual(sut.tracks, [updatedTrack])
        XCTAssertEqual(title.text, updatedTrack.title)
        XCTAssertEqual(playedQueues.count, 3)
        XCTAssertTrue(playedQueues.allSatisfy { $0 == [updatedTrack] })
    }

    /// 如果重命名行 action 没有作用于选中列表或绕过共享 ViewModel，此测试应失败。
    @MainActor
    func testPlaylistRenameContextualActionRenamesSelectedPlaylist() throws {
        let libraryViewModel = LibraryViewModel(
            library: StubMusicLibrary(tracks: []),
            localStore: StubLocalMusicStore(tracks: [])
        )
        let store = try PlaylistStore.inMemory()
        _ = try store.create(name: "Old Name")
        _ = try store.create(name: "Delete Me")
        let playlistViewModel = try PlaylistViewModel(store: store, library: libraryViewModel)
        let sut = PlaylistListViewController(viewModel: playlistViewModel, onPlay: { _, _ in })
        let navigation = UINavigationController(rootViewController: sut)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = navigation
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        navigation.view.layoutIfNeeded()

        let table = try XCTUnwrap(
            allSubviews(in: sut.view).compactMap { $0 as? UITableView }.first
        )
        let renameConfiguration = try XCTUnwrap(
            sut.tableView(
                table,
                trailingSwipeActionsConfigurationForRowAt: IndexPath(row: 0, section: 0)
            )
        )
        let renameAction = try XCTUnwrap(
            renameConfiguration.actions.first { $0.style == .normal }
        )
        var didCompleteRename = false
        renameAction.handler(renameAction, table) { didCompleteRename = $0 }
        let alert = try XCTUnwrap(sut.presentedViewController as? UIAlertController)
        let textField = try XCTUnwrap(alert.textFields?.first)
        XCTAssertEqual(textField.text, "Old Name")
        textField.text = "New Name"
        textField.sendActions(for: .editingDidEndOnExit)
        XCTAssertTrue(didCompleteRename)
        XCTAssertEqual(playlistViewModel.playlists.map(\.name), ["New Name", "Delete Me"])
    }

    /// 如果删除行 action 没有作用于选中列表或只改表格快照，此测试应失败。
    @MainActor
    func testPlaylistDeleteContextualActionDeletesSelectedPlaylist() throws {
        let libraryViewModel = LibraryViewModel(
            library: StubMusicLibrary(tracks: []),
            localStore: StubLocalMusicStore(tracks: [])
        )
        let store = try PlaylistStore.inMemory()
        _ = try store.create(name: "Keep Me")
        _ = try store.create(name: "Delete Me")
        let playlistViewModel = try PlaylistViewModel(store: store, library: libraryViewModel)
        let sut = PlaylistListViewController(viewModel: playlistViewModel, onPlay: { _, _ in })
        sut.loadViewIfNeeded()
        let table = try XCTUnwrap(
            allSubviews(in: sut.view).compactMap { $0 as? UITableView }.first
        )

        let deleteConfiguration = try XCTUnwrap(
            sut.tableView(
                table,
                trailingSwipeActionsConfigurationForRowAt: IndexPath(row: 1, section: 0)
            )
        )
        let deleteAction = try XCTUnwrap(
            deleteConfiguration.actions.first { $0.style == .destructive }
        )
        var didCompleteDelete = false
        deleteAction.handler(deleteAction, table) { didCompleteDelete = $0 }
        XCTAssertTrue(didCompleteDelete)
        XCTAssertEqual(playlistViewModel.playlists.map(\.name), ["Keep Me"])
    }

    /// 如果环境依赖组装丢弃共享实例或重新创建播放列表状态，此测试应失败。
    @MainActor
    func testEnvironmentDependenciesPreservePlaylistViewModelIdentity() throws {
        let environment = AppEnvironment(
            downloadStorageResolution: DownloadStorageResolution(store: nil, warning: nil)
        )

        let dependencies = AppRootDependencies(environment: environment)

        let injected = try XCTUnwrap(dependencies.playlistViewModel)
        XCTAssertTrue(injected === environment.playlistViewModel)
    }

    /// 如果手机或 iPad 根容器没有把同一个播放列表状态注入资料库和搜索页，此测试应失败。
    @MainActor
    func testPhoneAndPadRootsInjectSharedPlaylistViewModel() throws {
        let libraryViewModel = LibraryViewModel(
            library: StubMusicLibrary(tracks: []),
            localStore: StubLocalMusicStore(tracks: [])
        )
        let playlistViewModel = try PlaylistViewModel(
            store: PlaylistStore.inMemory(),
            library: libraryViewModel
        )
        let snapshots = CurrentValueSubject<PlaybackSnapshot, Never>(PlaybackSnapshot())
        let dependencies = AppRootDependencies(
            identity: NSObject(),
            libraryViewModel: libraryViewModel,
            playlistViewModel: playlistViewModel,
            snapshotPublisher: snapshots.eraseToAnyPublisher(),
            onPlay: { _, _ in },
            onTogglePlay: {}
        )
        let phone = MainTabBarController(dependencies: dependencies)
        let pad = PadRootViewController(dependencies: dependencies)
        phone.loadViewIfNeeded()
        pad.loadViewIfNeeded()

        let phoneLibrary = try XCTUnwrap(descendant(LibraryViewController.self, in: phone))
        let padLibrary = try XCTUnwrap(descendant(LibraryViewController.self, in: pad))
        let phoneSearch = try XCTUnwrap(descendant(SearchViewController.self, in: phone))
        try XCTUnwrap(findView(identifier: "pad.search", in: pad.view) as? UIButton)
            .sendActions(for: .touchUpInside)
        let padSearch = try XCTUnwrap(descendant(SearchViewController.self, in: pad))
        XCTAssertTrue(phoneLibrary.playlistViewModel === playlistViewModel)
        XCTAssertTrue(padLibrary.playlistViewModel === playlistViewModel)
        XCTAssertTrue(phoneSearch.playlistViewModel === playlistViewModel)
        XCTAssertTrue(padSearch.playlistViewModel === playlistViewModel)
    }

    /// Play All、Shuffle 与 Sort 必须作用于当前共享队列，而不是只显示静态按钮。
    @MainActor
    func testTrackListActionsInvokePlaybackAndSortVisibleTracks() throws {
        let second = makeTrack(id: "second", title: "B Song", artist: "A Artist", album: "B Album")
        let first = makeTrack(id: "first", title: "A Song", artist: "B Artist", album: "A Album")
        var playedQueues = [[SimpleMusic.MusicTrack]]()
        let sut = TrackListViewController(
            category: .songs,
            tracks: [second, first],
            onPlay: { queue, index in
                XCTAssertEqual(index, 0)
                playedQueues.append(queue)
            }
        )
        sut.loadViewIfNeeded()

        try XCTUnwrap(findView(identifier: "list.playAll", in: sut.view) as? UIButton)
            .sendActions(for: .touchUpInside)
        try XCTUnwrap(findView(identifier: "list.shuffle", in: sut.view) as? UIButton)
            .sendActions(for: .touchUpInside)
        try XCTUnwrap(findView(identifier: "list.sort", in: sut.view) as? UIButton)
            .sendActions(for: .touchUpInside)

        XCTAssertEqual(playedQueues.first?.map(\.id), ["second", "first"])
        XCTAssertEqual(Set(playedQueues.last?.map(\.id) ?? []), Set(["second", "first"]))
        XCTAssertEqual(sut.tracks.map(\.id), ["first", "second"])
    }

    /// Albums/Artists 必须先按真实元数据分组，并能进入对应歌曲子列表。
    @MainActor
    func testAlbumCategoryGroupsTracksAndPushesSelectedSongs() throws {
        let beta = makeTrack(id: "beta", title: "Beta", album: "Beta Album")
        let alpha = makeTrack(id: "alpha", title: "Alpha", album: "Alpha Album")
        let sut = TrackListViewController(
            category: .albums,
            tracks: [beta, alpha],
            onPlay: { _, _ in }
        )
        let navigation = UINavigationController(rootViewController: sut)
        navigation.loadViewIfNeeded()
        sut.loadViewIfNeeded()
        let collection = try XCTUnwrap(
            allSubviews(in: sut.view).compactMap { $0 as? UICollectionView }.first
        )

        XCTAssertEqual(collection.numberOfItems(inSection: 0), 2)
        collection.delegate?.collectionView?(
            collection,
            didSelectItemAt: IndexPath(item: 0, section: 0)
        )
        XCTAssertEqual(navigation.topViewController?.title, "Alpha Album")
        XCTAssertFalse(navigation.topViewController === sut)
    }

    /// 生产 Downloaded 页面打开后，共享删除 reload 必须立即移除当前页歌曲行。
    @MainActor
    func testProductionDownloadedListUpdatesAfterSharedDeleteReload() async throws {
        let track = makeTrack(
            id: "live-delete",
            source: .downloaded(fileName: "live-delete.m4a")
        )
        let localStore = DeletingLocalMusicStore(tracks: [track])
        let viewModel = LibraryViewModel(
            library: StubMusicLibrary(tracks: []),
            localStore: localStore,
            deleteLocalTrack: { localStore.delete($0) }
        )
        await viewModel.requestReload()
        let library = LibraryViewController(viewModel: viewModel)
        let navigation = UINavigationController(rootViewController: library)
        navigation.loadViewIfNeeded()
        library.loadViewIfNeeded()
        let libraryCollection = try XCTUnwrap(
            allSubviews(in: library.view).compactMap { $0 as? UICollectionView }.first
        )
        library.collectionView(
            libraryCollection,
            didSelectItemAt: IndexPath(item: 3, section: 0)
        )
        let list = try XCTUnwrap(navigation.topViewController as? TrackListViewController)
        list.loadViewIfNeeded()
        let listCollection = try XCTUnwrap(
            allSubviews(in: list.view).compactMap { $0 as? UICollectionView }.first
        )
        XCTAssertEqual(listCollection.numberOfItems(inSection: 0), 1)

        await viewModel.deleteDownloadedTrack(track)

        XCTAssertTrue(viewModel.tracks.isEmpty)
        XCTAssertTrue(list.tracks.isEmpty)
        XCTAssertEqual(listCollection.numberOfItems(inSection: 0), 0)
    }

    /// Songs 页面打开后撤销系统权限，当前页必须随共享 reload 清除系统歌曲。
    @MainActor
    func testProductionSongsListUpdatesAfterPermissionRevocation() async throws {
        let systemTrack = makeTrack(id: "live-system", source: .system(persistentID: 88))
        let systemLibrary = DeferredMusicLibrary()
        let viewModel = LibraryViewModel(
            library: systemLibrary,
            localStore: StubLocalMusicStore(tracks: [])
        )
        let initialReload = Task { await viewModel.requestReload() }
        let initialRequestStarted = await eventually { systemLibrary.requestCount == 1 }
        XCTAssertTrue(initialRequestStarted)
        systemLibrary.resumeRequest(at: 0, with: [systemTrack])
        await initialReload.value
        let library = LibraryViewController(viewModel: viewModel)
        let navigation = UINavigationController(rootViewController: library)
        navigation.loadViewIfNeeded()
        library.loadViewIfNeeded()
        let libraryCollection = try XCTUnwrap(
            allSubviews(in: library.view).compactMap { $0 as? UICollectionView }.first
        )
        library.collectionView(
            libraryCollection,
            didSelectItemAt: IndexPath(item: 0, section: 0)
        )
        let list = try XCTUnwrap(navigation.topViewController as? TrackListViewController)
        list.loadViewIfNeeded()

        systemLibrary.authorizationStatus = .denied
        await viewModel.requestReload()

        XCTAssertTrue(viewModel.tracks.isEmpty)
        XCTAssertTrue(list.tracks.isEmpty)
    }

    /// Albums 与 Artists 子页必须按同一 ViewModel 的最新 tracks 重筛，Play All 也只能使用新队列。
    @MainActor
    func testProductionAlbumAndArtistChildrenUpdateAfterMediaReload() async throws {
        let scenarios: [(
            categoryIndex: Int,
            initial: SimpleMusic.MusicTrack,
            added: SimpleMusic.MusicTrack,
            other: SimpleMusic.MusicTrack
        )] = [
            (
                1,
                makeTrack(id: "album-old", title: "Old", artist: "A", album: "Shared Album"),
                makeTrack(id: "album-new", title: "New", artist: "B", album: "Shared Album"),
                makeTrack(id: "album-other", title: "Other", artist: "C", album: "Other Album")
            ),
            (
                2,
                makeTrack(id: "artist-old", title: "Old", artist: "Shared Artist", album: "A"),
                makeTrack(id: "artist-new", title: "New", artist: "Shared Artist", album: "B"),
                makeTrack(id: "artist-other", title: "Other", artist: "Other Artist", album: "C")
            )
        ]

        for scenario in scenarios {
            let systemLibrary = DeferredMusicLibrary()
            let viewModel = LibraryViewModel(
                library: systemLibrary,
                localStore: StubLocalMusicStore(tracks: [])
            )
            let initialReload = Task { await viewModel.requestReload() }
            let initialRequestStarted = await eventually { systemLibrary.requestCount == 1 }
            XCTAssertTrue(initialRequestStarted)
            systemLibrary.resumeRequest(at: 0, with: [scenario.initial])
            await initialReload.value
            var playedIDs = [[String]]()
            let library = LibraryViewController(viewModel: viewModel)
            library.onSelectTrack = { queue, _ in playedIDs.append(queue.map(\.id)) }
            let navigation = UINavigationController(rootViewController: library)
            navigation.loadViewIfNeeded()
            library.loadViewIfNeeded()
            let libraryCollection = try XCTUnwrap(
                allSubviews(in: library.view).compactMap { $0 as? UICollectionView }.first
            )
            library.collectionView(
                libraryCollection,
                didSelectItemAt: IndexPath(item: scenario.categoryIndex, section: 0)
            )
            let groupedList = try XCTUnwrap(
                navigation.topViewController as? TrackListViewController
            )
            groupedList.loadViewIfNeeded()
            let groupedCollection = try XCTUnwrap(
                allSubviews(in: groupedList.view).compactMap { $0 as? UICollectionView }.first
            )
            groupedList.collectionView(
                groupedCollection,
                didSelectItemAt: IndexPath(item: 0, section: 0)
            )
            let childList = try XCTUnwrap(
                navigation.topViewController as? TrackListViewController
            )
            childList.loadViewIfNeeded()

            let refresh = Task { await viewModel.requestReload() }
            let refreshStarted = await eventually { systemLibrary.requestCount == 2 }
            XCTAssertTrue(refreshStarted)
            systemLibrary.resumeRequest(
                at: 1,
                with: [scenario.initial, scenario.added, scenario.other]
            )
            await refresh.value
            try XCTUnwrap(findView(identifier: "list.sort", in: childList.view) as? UIButton)
                .sendActions(for: .touchUpInside)
            try XCTUnwrap(findView(identifier: "list.playAll", in: childList.view) as? UIButton)
                .sendActions(for: .touchUpInside)
            try XCTUnwrap(findView(identifier: "list.shuffle", in: childList.view) as? UIButton)
                .sendActions(for: .touchUpInside)

            XCTAssertEqual(
                childList.tracks.map(\.id),
                [scenario.added.id, scenario.initial.id]
            )
            XCTAssertEqual(
                Set(playedIDs.first ?? []),
                Set([scenario.initial.id, scenario.added.id])
            )
            XCTAssertEqual(
                Set(playedIDs.last ?? []),
                Set([scenario.initial.id, scenario.added.id])
            )
        }
    }

    /// 如果下载标识固定 22pt，或歌曲行不能随辅助字号自适应增长，此测试应失败。
    @MainActor
    func testTrackCellSelfSizesDownloadedBadgeAtAccessibilitySize() async throws {
        let accessibilityTraits = UITraitCollection(
            preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge
        )
        let track = makeTrack(
            id: "downloaded-accessibility",
            title: "歌曲",
            artist: "艺人",
            album: "专辑",
            source: .downloaded(fileName: "song.m4a")
        )
        let viewModel = LibraryViewModel(
            library: StubMusicLibrary(tracks: []),
            localStore: StubLocalMusicStore(tracks: [track])
        )
        await viewModel.reload()

        let host = UIViewController()
        let search = SearchViewController(viewModel: viewModel)
        host.loadViewIfNeeded()
        host.view.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        host.addChild(search)
        host.setOverrideTraitCollection(accessibilityTraits, forChild: search)
        host.view.addSubview(search.view)
        search.view.frame = host.view.bounds
        search.didMove(toParent: host)
        search.collectionView.reloadData()
        search.collectionView.collectionViewLayout.invalidateLayout()
        host.view.layoutIfNeeded()
        search.collectionView.layoutIfNeeded()

        let cell = try XCTUnwrap(
            search.collectionView.cellForItem(at: IndexPath(item: 0, section: 0)) as? TrackCell
        )
        cell.setNeedsLayout()
        cell.layoutIfNeeded()

        let artwork = try XCTUnwrap(findView(identifier: "track.artwork", in: cell))
        let title = try XCTUnwrap(findView(identifier: "track.title", in: cell) as? UILabel)
        let subtitle = try XCTUnwrap(findView(identifier: "track.subtitle", in: cell) as? UILabel)
        let badge = try XCTUnwrap(findView(identifier: "track.downloaded", in: cell) as? UILabel)
        let more = try XCTUnwrap(findView(identifier: "track.more", in: cell) as? UIButton)

        XCTAssertGreaterThan(
            title.font.lineHeight,
            UIFont.preferredFont(forTextStyle: .body).lineHeight
        )
        XCTAssertGreaterThan(cell.bounds.height, 66)
        XCTAssertFalse(cell.contentView.hasAmbiguousLayout)
        XCTAssertGreaterThanOrEqual(badge.bounds.height + 0.5, badge.font.lineHeight + 8)
        XCTAssertGreaterThanOrEqual(badge.bounds.width + 0.5, badge.intrinsicContentSize.width)
        XCTAssertGreaterThanOrEqual(title.bounds.height + 0.5, title.font.lineHeight)
        XCTAssertGreaterThanOrEqual(subtitle.bounds.height + 0.5, subtitle.font.lineHeight)
        XCTAssertTrue(artwork.constraints.contains {
            $0.isActive && $0.firstAttribute == .height && $0.constant == 46
        })
        XCTAssertGreaterThanOrEqual(more.bounds.height, 44)
    }

    /// 如果 iPad 切换或重复点击侧栏时重建导航并脱离共享页面，此测试应失败。
    @MainActor
    func testPadSidebarKeepsSharedPagesContainedAcrossSwitches() throws {
        let viewModel = LibraryViewModel(
            library: StubMusicLibrary(tracks: []),
            localStore: StubLocalMusicStore(tracks: [])
        )
        let snapshots = CurrentValueSubject<PlaybackSnapshot, Never>(PlaybackSnapshot())
        let sut = PadRootViewController(
            nowPlayingViewController: UIViewController(),
            libraryViewModel: viewModel,
            snapshotPublisher: snapshots.eraseToAnyPublisher(),
            onPlay: { _, _ in },
            onTogglePlay: {},
            onOpenPlayer: {}
        )
        sut.loadViewIfNeeded()
        let libraryButton = try XCTUnwrap(
            findView(identifier: "pad.library", in: sut.view) as? UIButton
        )
        let searchButton = try XCTUnwrap(
            findView(identifier: "pad.search", in: sut.view) as? UIButton
        )
        let sidebar = try XCTUnwrap(findView(identifier: "pad.sidebar", in: sut.view))
        let sidebarText = allSubviews(in: sidebar)
            .compactMap { ($0 as? UILabel)?.text }

        XCTAssertEqual(libraryButton.configuration?.title, L10n.text("tab.library"))
        XCTAssertEqual(searchButton.configuration?.title, L10n.text("tab.search"))
        XCTAssertTrue(sidebarText.contains(L10n.text("app.name")))
        searchButton.sendActions(for: .touchUpInside)
        let search = try XCTUnwrap(descendant(SearchViewController.self, in: sut))
        XCTAssertTrue(search.viewModel === viewModel)

        libraryButton.sendActions(for: .touchUpInside)
        libraryButton.sendActions(for: .touchUpInside)
        let library = try XCTUnwrap(descendant(LibraryViewController.self, in: sut))
        XCTAssertTrue(library.viewModel === viewModel)
        XCTAssertTrue(library.navigationController?.parent === sut)
    }

    private func makeTrack(
        id: String,
        title: String = "歌曲",
        artist: String = "艺人",
        album: String = "专辑",
        artworkData: Data? = nil,
        source: SimpleMusic.MusicSource = .system(persistentID: 99)
    ) -> SimpleMusic.MusicTrack {
        SimpleMusic.MusicTrack(
            id: id,
            title: title,
            artist: artist,
            album: album,
            duration: 180,
            artworkData: artworkData,
            source: source
        )
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

    nonisolated private static func systemMetadata(id: UInt64) -> SystemTrackMetadata {
        SystemTrackMetadata(
            persistentID: id,
            title: "系统歌曲 \(id)",
            artist: "系统艺人",
            album: "系统专辑",
            duration: 180,
            artworkData: nil
        )
    }

    nonisolated private static func localRecord(id: String) -> LocalTrackRecord {
        LocalTrackRecord(
            id: id,
            fileName: "\(id).m4a",
            title: "本地歌曲",
            artist: "本地艺人",
            album: "本地专辑",
            duration: 180
        )
    }

    private func findView(identifier: String, in root: UIView) -> UIView? {
        if root.accessibilityIdentifier == identifier { return root }
        return root.subviews.lazy.compactMap {
            self.findView(identifier: identifier, in: $0)
        }.first
    }

    private func allSubviews(in root: UIView) -> [UIView] {
        [root] + root.subviews.flatMap(allSubviews)
    }

    @MainActor
    private func activateAlertAction(named title: String, in alert: UIAlertController) -> Bool {
        typealias Handler = @convention(block) (UIAlertAction) -> Void
        guard let action = alert.actions.first(where: { $0.title == title }),
              let rawHandler = action.value(forKey: "handler") else {
            return false
        }
        let handler = unsafeBitCast(rawHandler as AnyObject, to: Handler.self)
        handler(action)
        return true
    }

    private func selectCategory(named name: String, in library: LibraryViewController) {
        guard let collection = allSubviews(in: library.view)
            .compactMap({ $0 as? UICollectionView })
            .first else {
            return XCTFail("资料库缺少分类 collection view")
        }
        for section in 0..<library.numberOfSections(in: collection) {
            let itemCount = library.collectionView(collection, numberOfItemsInSection: section)
            for item in 0..<itemCount {
                let indexPath = IndexPath(item: item, section: section)
                let cell = library.collectionView(collection, cellForItemAt: indexPath)
                guard cell.accessibilityLabel == name else { continue }
                library.collectionView(collection, didSelectItemAt: indexPath)
                return
            }
        }
        XCTFail("未找到分类：\(name)")
    }

    private func descendant<T: UIViewController>(
        _ type: T.Type,
        in root: UIViewController
    ) -> T? {
        if let match = root as? T { return match }
        return root.children.lazy.compactMap {
            self.descendant(type, in: $0)
        }.first
    }

    @MainActor
    private func waitUntil(
        attempts: Int = 100,
        condition: @escaping @MainActor () -> Bool
    ) async {
        _ = await eventually(attempts: attempts, condition: condition)
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

    /// 即使断言在旧实现上失败，也释放所有 continuation，避免测试任务泄漏。
    @MainActor
    private func finishReloads(
        _ tasks: [Task<Void, Never>],
        expectedRequests: Int,
        library: DeferredMusicLibrary,
        localStore: DeferredLocalMusicStore
    ) async {
        for index in 0..<expectedRequests {
            if await eventually(condition: { library.requestCount > index }) {
                library.resumeRequestIfPending(at: index, with: [])
            }
        }
        for index in 0..<expectedRequests {
            if await eventually(condition: { localStore.requestCount > index }) {
                localStore.resumeRequestIfPending(at: index, with: [])
            }
        }
        for task in tasks {
            await task.value
        }
    }
}

private enum TestError: Error {
    case unavailable
}

private final class StubMusicLibrary: MusicLibraryLoading {
    @MainActor let authorizationStatus: MPMediaLibraryAuthorizationStatus
    private let result: Result<[SimpleMusic.MusicTrack], Error>

    init(
        tracks: [SimpleMusic.MusicTrack] = [],
        authorizationStatus: MPMediaLibraryAuthorizationStatus = .authorized
    ) {
        self.authorizationStatus = authorizationStatus
        result = .success(tracks)
    }

    init(
        error: Error,
        authorizationStatus: MPMediaLibraryAuthorizationStatus = .authorized
    ) {
        self.authorizationStatus = authorizationStatus
        result = .failure(error)
    }

    func loadTracks() async throws -> [SimpleMusic.MusicTrack] {
        try result.get()
    }
}

private final class StubLocalMusicStore: LocalMusicLoading {
    private let result: Result<[SimpleMusic.MusicTrack], Error>

    init(tracks: [SimpleMusic.MusicTrack]) {
        result = .success(tracks)
    }

    init(error: Error) {
        result = .failure(error)
    }

    func loadTracks() async throws -> [SimpleMusic.MusicTrack] {
        try result.get()
    }
}

@MainActor
private final class DeletingLocalMusicStore: LocalMusicLoading {
    private var tracks: [SimpleMusic.MusicTrack]
    private(set) var deletedIDs = [String]()
    private(set) var loadCount = 0

    init(tracks: [SimpleMusic.MusicTrack]) {
        self.tracks = tracks
    }

    func loadTracks() async throws -> [SimpleMusic.MusicTrack] {
        loadCount += 1
        return tracks
    }

    func delete(_ track: SimpleMusic.MusicTrack) {
        deletedIDs.append(track.id)
        tracks.removeAll { $0.id == track.id }
    }
}

private final class DeferredMusicLibrary: MusicLibraryLoading {
    @MainActor var authorizationStatus: MPMediaLibraryAuthorizationStatus
    @MainActor private var requests = [DeferredTrackRequest]()

    init(authorizationStatus: MPMediaLibraryAuthorizationStatus = .authorized) {
        self.authorizationStatus = authorizationStatus
    }

    @MainActor var requestCount: Int { requests.count }

    nonisolated func loadTracks() async throws -> [SimpleMusic.MusicTrack] {
        try await withCheckedThrowingContinuation { continuation in
            Task { @MainActor in
                self.requests.append(DeferredTrackRequest(continuation: continuation))
            }
        }
    }

    @MainActor
    func resumeRequest(at index: Int, with tracks: [SimpleMusic.MusicTrack]) {
        resumeRequestIfPending(at: index, with: tracks)
    }

    @MainActor
    func resumeRequest(at index: Int, throwing error: Error) {
        guard requests.indices.contains(index), !requests[index].isResumed else { return }
        requests[index].isResumed = true
        requests[index].continuation.resume(throwing: error)
    }

    @MainActor
    func resumeRequestIfPending(at index: Int, with tracks: [SimpleMusic.MusicTrack]) {
        guard requests.indices.contains(index), !requests[index].isResumed else { return }
        requests[index].isResumed = true
        requests[index].continuation.resume(returning: tracks)
    }
}

private final class DeferredLocalMusicStore: LocalMusicLoading {
    @MainActor private var requests = [DeferredTrackRequest]()

    @MainActor var requestCount: Int { requests.count }

    nonisolated func loadTracks() async throws -> [SimpleMusic.MusicTrack] {
        try await withCheckedThrowingContinuation { continuation in
            Task { @MainActor in
                self.requests.append(DeferredTrackRequest(continuation: continuation))
            }
        }
    }

    @MainActor
    func resumeRequest(at index: Int, with tracks: [SimpleMusic.MusicTrack]) {
        resumeRequestIfPending(at: index, with: tracks)
    }

    @MainActor
    func resumeRequest(at index: Int, throwing error: Error) {
        guard requests.indices.contains(index), !requests[index].isResumed else { return }
        requests[index].isResumed = true
        requests[index].continuation.resume(throwing: error)
    }

    @MainActor
    func resumeRequestIfPending(at index: Int, with tracks: [SimpleMusic.MusicTrack]) {
        guard requests.indices.contains(index), !requests[index].isResumed else { return }
        requests[index].isResumed = true
        requests[index].continuation.resume(returning: tracks)
    }
}

private struct DeferredTrackRequest {
    let continuation: CheckedContinuation<[SimpleMusic.MusicTrack], Error>
    var isResumed = false
}

private final class ProductionQueryGate: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)

    func wait() {
        _ = semaphore.wait(timeout: .now() + 2)
    }

    func open() {
        semaphore.signal()
    }
}

private final class ProductionThreadProbe: @unchecked Sendable {
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

private final class ProductionSystemQuerySequence: @unchecked Sendable {
    private let lock = NSLock()
    private let firstGate = DispatchSemaphore(value: 0)
    private var count = 0

    var queryCount: Int {
        lock.withLock { count }
    }

    func query() -> [SystemTrackMetadata] {
        let index = lock.withLock {
            count += 1
            return count
        }
        if index == 1 {
            _ = firstGate.wait(timeout: .now() + 2)
        }
        return [SystemTrackMetadata(
            persistentID: index == 1 ? 101 : 202,
            title: "系统歌曲",
            artist: "系统艺人",
            album: "系统专辑",
            duration: 180,
            artworkData: nil
        )]
    }

    func releaseFirst() {
        firstGate.signal()
    }
}
