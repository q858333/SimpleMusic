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
        XCTAssertEqual(toggle.accessibilityLabel, "暂停")

        snapshots.send(PlaybackSnapshot(status: .failed("失败"), track: track))
        await waitUntil { toggle.accessibilityLabel == "播放" }
        XCTAssertEqual(toggle.accessibilityLabel, "播放")
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
        XCTAssertTrue(more.constraints.contains {
            $0.firstAttribute == .width && $0.relation == .greaterThanOrEqual && $0.constant >= 44
        })
    }

    /// 系统歌曲没有本地删除动作，不能显示会产生空回调的“更多”按钮。
    @MainActor
    func testTrackCellHidesMoreActionForSystemTrack() throws {
        let cell = TrackCell(frame: CGRect(x: 0, y: 0, width: 360, height: 66))
        cell.configure(with: makeTrack(id: "system", source: .system(persistentID: 7)))

        let more = try XCTUnwrap(findView(identifier: "track.more", in: cell))
        XCTAssertTrue(more.isHidden)
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
        XCTAssertEqual(navigation.topViewController?.title, "歌曲")
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
        source: SimpleMusic.MusicSource = .system(persistentID: 99)
    ) -> SimpleMusic.MusicTrack {
        SimpleMusic.MusicTrack(
            id: id,
            title: title,
            artist: artist,
            album: album,
            duration: 180,
            artworkData: nil,
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
