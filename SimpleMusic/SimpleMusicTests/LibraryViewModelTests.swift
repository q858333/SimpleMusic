import Combine
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

@MainActor
private final class StubMusicLibrary: MusicLibraryLoading {
    let authorizationStatus: MPMediaLibraryAuthorizationStatus
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

@MainActor
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
private final class DeferredMusicLibrary: MusicLibraryLoading {
    let authorizationStatus = MPMediaLibraryAuthorizationStatus.authorized
    private var requests = [DeferredTrackRequest]()

    var requestCount: Int { requests.count }

    func loadTracks() async throws -> [SimpleMusic.MusicTrack] {
        try await withCheckedThrowingContinuation { continuation in
            requests.append(DeferredTrackRequest(continuation: continuation))
        }
    }

    func resumeRequest(at index: Int, with tracks: [SimpleMusic.MusicTrack]) {
        resumeRequestIfPending(at: index, with: tracks)
    }

    func resumeRequest(at index: Int, throwing error: Error) {
        guard requests.indices.contains(index), !requests[index].isResumed else { return }
        requests[index].isResumed = true
        requests[index].continuation.resume(throwing: error)
    }

    func resumeRequestIfPending(at index: Int, with tracks: [SimpleMusic.MusicTrack]) {
        guard requests.indices.contains(index), !requests[index].isResumed else { return }
        requests[index].isResumed = true
        requests[index].continuation.resume(returning: tracks)
    }
}

@MainActor
private final class DeferredLocalMusicStore: LocalMusicLoading {
    private var requests = [DeferredTrackRequest]()

    var requestCount: Int { requests.count }

    func loadTracks() async throws -> [SimpleMusic.MusicTrack] {
        try await withCheckedThrowingContinuation { continuation in
            requests.append(DeferredTrackRequest(continuation: continuation))
        }
    }

    func resumeRequest(at index: Int, with tracks: [SimpleMusic.MusicTrack]) {
        resumeRequestIfPending(at: index, with: tracks)
    }

    func resumeRequest(at index: Int, throwing error: Error) {
        guard requests.indices.contains(index), !requests[index].isResumed else { return }
        requests[index].isResumed = true
        requests[index].continuation.resume(throwing: error)
    }

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
