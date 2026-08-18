import AVFoundation
import MediaPlayer
import XCTest
@testable import SimpleMusic

@MainActor
final class PlaybackBackendLifecycleTests: XCTestCase {
    /// 显式 stop 即使同步产生 stopped/item-nil 通知，也不能冒充自然结束。
    func testSystemBackendDoesNotFinishForExplicitStop() throws {
        let harness = SystemBackendHarness()
        let generation = PlaybackGeneration(rawValue: 2)
        try harness.backend.load(systemTrack(id: 12), generation: generation)
        harness.backend.play()
        harness.driver.publishPlaying(persistentID: 12)
        harness.driver.postsNotificationsWhenStopped = true

        harness.backend.stop()

        XCTAssertTrue(harness.delegate.finishedGenerations.isEmpty)
    }

    /// 若同源切换后旧 stopped 复用新 generation，第二首会被误判结束。
    func testSystemBackendIgnoresStoppedNotificationsFromPreviousLoad() throws {
        let harness = SystemBackendHarness()
        let firstGeneration = PlaybackGeneration(rawValue: 1)
        let secondGeneration = PlaybackGeneration(rawValue: 2)
        try harness.backend.load(systemTrack(id: 11), generation: firstGeneration)
        harness.backend.play()
        harness.driver.publishPlaying(persistentID: 11)
        harness.driver.currentPlaybackTime = 60
        harness.driver.currentDuration = 60
        harness.timer.fire()

        try harness.backend.load(systemTrack(id: 22), generation: secondGeneration)
        harness.backend.play()
        harness.driver.publishPlaying(persistentID: 22)

        // 旧曲迟到的 stopped 不能预先满足新曲的完成证据。
        harness.driver.publishStopped()
        harness.driver.currentPlaybackTime = 1
        harness.driver.currentDuration = 60
        harness.timer.fire()
        harness.driver.currentPlaybackTime = 60
        harness.driver.currentDuration = 60
        harness.timer.fire()
        harness.driver.publishItemChange(persistentID: nil)

        XCTAssertTrue(harness.delegate.finishedGenerations.isEmpty)

        harness.driver.publishStopped()

        XCTAssertEqual(harness.delegate.finishedGenerations, [secondGeneration])
    }

    /// 若每次 load 没有生成独立 observer，旧 block 会把 stopped 证据拼到已到末尾的新 generation。
    func testSystemBackendRejectsQueuedStoppedBlockFromPreviousGenerationAtCurrentEnd() throws {
        let driver = FakeSystemPlaybackDriver()
        let center = NotificationCenter()
        let timer = TestPlaybackTimer()
        let observerRecorder = SystemObserverRecorder(driver: driver)
        let delegate = RecordingPlaybackDelegate()
        let backend = SystemPlaybackBackend(
            driver: driver,
            notificationCenter: center,
            timerFactory: { callback in
                timer.callback = callback
                return timer
            },
            observerFactory: { name, object, handler in
                observerRecorder.makeObserver(forName: name, object: object, handler: handler)
            }
        )
        backend.delegate = delegate
        let firstGeneration = PlaybackGeneration(rawValue: 31)
        let secondGeneration = PlaybackGeneration(rawValue: 32)
        try backend.load(systemTrack(id: 11), generation: firstGeneration)
        backend.play()
        driver.currentPersistentID = 11
        driver.playbackState = .playing
        observerRecorder.firePlaybackStateObserver(at: 0)

        try backend.load(systemTrack(id: 22), generation: secondGeneration)
        backend.play()
        driver.currentPersistentID = 22
        driver.playbackState = .playing
        observerRecorder.firePlaybackStateObserver(at: 1)
        driver.currentPlaybackTime = 60
        driver.currentDuration = 60
        timer.fire()

        driver.currentPersistentID = nil
        driver.playbackState = .stopped
        observerRecorder.firePlaybackStateObserver(at: 0)
        observerRecorder.fireItemObserver(at: 1)

        XCTAssertTrue(delegate.finishedGenerations.isEmpty)

        observerRecorder.firePlaybackStateObserver(at: 1)
        XCTAssertEqual(delegate.finishedGenerations, [secondGeneration])
    }

    /// stopped 可能早于 item-nil；已进入一个计时周期内的末尾证据必须保留到 removal 到达。
    func testSystemBackendFinishesWhenStoppedArrivesBeforeItemRemovalAtEnd() throws {
        let harness = SystemBackendHarness()
        let generation = PlaybackGeneration(rawValue: 3)
        try harness.backend.load(systemTrack(id: 33), generation: generation)
        harness.backend.play()
        harness.driver.publishPlaying(persistentID: 33)
        harness.driver.currentPlaybackTime = 59.2
        harness.driver.currentDuration = 60
        harness.timer.fire()

        harness.driver.publishStopped()
        XCTAssertTrue(harness.delegate.finishedGenerations.isEmpty)
        harness.driver.publishItemChange(persistentID: nil)

        XCTAssertEqual(harness.delegate.finishedGenerations, [generation])
    }

    /// 中途外部 stop 即使同时移除 item，也不能冒充自然结束。
    func testSystemBackendDoesNotFinishExternalStopWithItemRemovalBeforeEnd() throws {
        let harness = SystemBackendHarness()
        let generation = PlaybackGeneration(rawValue: 34)
        try harness.backend.load(systemTrack(id: 34), generation: generation)
        harness.backend.play()
        harness.driver.publishPlaying(persistentID: 34)
        harness.driver.currentPlaybackTime = 42
        harness.driver.currentDuration = 60

        harness.driver.publishItemChange(persistentID: nil)
        harness.driver.currentDuration = 0
        harness.timer.fire()
        harness.driver.publishStopped()

        XCTAssertTrue(harness.delegate.finishedGenerations.isEmpty)
    }

    /// 末尾 tick 后回到中段时，最新进度必须撤销旧末尾证据。
    func testSystemBackendDoesNotReuseEndEvidenceAfterMiddleProgress() throws {
        let harness = SystemBackendHarness()
        let generation = PlaybackGeneration(rawValue: 36)
        try harness.backend.load(systemTrack(id: 36), generation: generation)
        harness.backend.play()
        harness.driver.publishPlaying(persistentID: 36)
        harness.driver.currentPlaybackTime = 59.2
        harness.driver.currentDuration = 60
        harness.timer.fire()

        harness.driver.currentPlaybackTime = 42
        harness.timer.fire()
        harness.driver.publishStopped()
        harness.driver.publishItemChange(persistentID: nil)

        XCTAssertTrue(harness.delegate.finishedGenerations.isEmpty)
    }

    /// seek 离开末尾窗口时，旧末尾 tick 不能继续参与完成判定。
    func testSystemBackendDoesNotReuseEndEvidenceAfterSeekingToMiddle() throws {
        let harness = SystemBackendHarness()
        let generation = PlaybackGeneration(rawValue: 37)
        try harness.backend.load(systemTrack(id: 37), generation: generation)
        harness.backend.play()
        harness.driver.publishPlaying(persistentID: 37)
        harness.driver.currentPlaybackTime = 59.2
        harness.driver.currentDuration = 60
        harness.timer.fire()

        harness.backend.seek(to: 42)
        harness.driver.publishStopped()
        harness.driver.publishItemChange(persistentID: nil)

        XCTAssertTrue(harness.delegate.finishedGenerations.isEmpty)
    }

    /// seek 到末尾本身不是自然结束进度；仍须后续 timer 确认。
    func testSystemBackendSeekToEndDoesNotCreateEndEvidence() throws {
        let harness = SystemBackendHarness()
        let generation = PlaybackGeneration(rawValue: 38)
        try harness.backend.load(systemTrack(id: 38), generation: generation)
        harness.backend.play()
        harness.driver.publishPlaying(persistentID: 38)

        harness.backend.seek(to: 59.2)
        harness.driver.publishStopped()
        harness.driver.publishItemChange(persistentID: nil)

        XCTAssertTrue(harness.delegate.finishedGenerations.isEmpty)
    }

    /// 外部 stop 即使发生在末尾窗口，只要没有 item removal 就不能完成。
    func testSystemBackendExternalStopWithoutItemRemovalDoesNotFinish() throws {
        let harness = SystemBackendHarness()
        let generation = PlaybackGeneration(rawValue: 35)
        try harness.backend.load(systemTrack(id: 35), generation: generation)
        harness.backend.play()
        harness.driver.publishPlaying(persistentID: 35)
        harness.driver.currentPlaybackTime = 60
        harness.driver.currentDuration = 60
        harness.timer.fire()

        harness.driver.publishStopped()

        XCTAssertTrue(harness.delegate.finishedGenerations.isEmpty)
    }

    /// item removal 后 duration 会归零；保存的末尾进度仍应让 removal→stopped 完成。
    func testSystemBackendFinishesWhenItemRemovalArrivesBeforeStoppedAtEnd() throws {
        let harness = SystemBackendHarness()
        let generation = PlaybackGeneration(rawValue: 9)
        try harness.backend.load(systemTrack(id: 99), generation: generation)
        harness.backend.play()
        harness.driver.publishPlaying(persistentID: 99)
        harness.driver.currentPlaybackTime = 59.2
        harness.driver.currentDuration = 60
        harness.timer.fire()

        harness.driver.currentDuration = 0
        harness.driver.publishItemChange(persistentID: nil)
        harness.driver.publishStopped()

        XCTAssertEqual(harness.delegate.finishedGenerations, [generation])
    }

    /// 完成后必须先清除 active identity；同 generation 的重复通知只能上报一次。
    func testSystemBackendFinishesSameGenerationExactlyOnce() throws {
        let harness = SystemBackendHarness()
        let generation = PlaybackGeneration(rawValue: 10)
        try harness.backend.load(systemTrack(id: 100), generation: generation)
        harness.backend.play()
        harness.driver.publishPlaying(persistentID: 100)
        harness.driver.currentPlaybackTime = 59.2
        harness.driver.currentDuration = 60
        harness.timer.fire()

        harness.driver.publishItemChange(persistentID: nil)
        harness.driver.publishStopped()
        harness.driver.publishItemChange(persistentID: nil)
        harness.driver.publishStopped()

        XCTAssertEqual(harness.delegate.finishedGenerations, [generation])
    }

    /// 若 Timer/observer 强持有后端，释放后不会 teardown 系统通知生成和计时器。
    func testSystemBackendReleasedOffMainEndsNotificationsOnMainExactlyOnce() async throws {
        let driver = FakeSystemPlaybackDriver()
        let center = NotificationCenter()
        let timer = TestPlaybackTimer()
        let delegate = RecordingPlaybackDelegate()
        driver.attach(notificationCenter: center)
        var backend: SystemPlaybackBackend? = SystemPlaybackBackend(
            driver: driver,
            notificationCenter: center,
            timerFactory: { callback in
                timer.callback = callback
                return timer
            }
        )
        backend?.delegate = delegate
        try backend?.load(systemTrack(id: 44), generation: PlaybackGeneration(rawValue: 4))
        backend?.play()
        weak let weakBackend = backend
        let releaseBox = LockedStrongBox(backend)

        backend = nil
        releaseOffMain(releaseBox)
        try await waitUntil { driver.endGeneratingThreads.count == 1 }
        driver.publishPlaying(persistentID: 44)
        driver.publishItemChange(persistentID: nil)
        driver.publishStopped()

        XCTAssertNil(weakBackend)
        XCTAssertTrue(timer.isInvalidated)
        XCTAssertEqual(driver.endGeneratingThreads, [true])
        XCTAssertTrue(delegate.finishedGenerations.isEmpty)
    }

    /// 若本地后端只按 backend 过滤通知，上一 AVPlayerItem 的迟到完成会结束新曲。
    func testLocalBackendIgnoresLateFinishFromPreviousItem() async throws {
        let fixture = try LocalBackendFixture()
        let firstGeneration = PlaybackGeneration(rawValue: 1)
        let secondGeneration = PlaybackGeneration(rawValue: 2)
        try fixture.backend.load(fixture.track(id: "first"), generation: firstGeneration)
        try await waitUntil { fixture.player.currentItem != nil }
        let firstItem = try XCTUnwrap(fixture.player.currentItem)
        try fixture.backend.load(fixture.track(id: "second"), generation: secondGeneration)
        try await waitUntil {
            fixture.player.currentItem != nil && fixture.player.currentItem !== firstItem
        }
        let secondItem = try XCTUnwrap(fixture.player.currentItem)

        fixture.center.post(name: .AVPlayerItemDidPlayToEndTime, object: firstItem)
        XCTAssertTrue(fixture.delegate.finishedGenerations.isEmpty)
        fixture.center.post(name: .AVPlayerItemDidPlayToEndTime, object: secondItem)

        XCTAssertEqual(fixture.delegate.finishedGenerations, [secondGeneration])
    }

    /// 若本地 observer/time observer 形成保留或未移除，后端释放后仍会响应迟到通知。
    func testLocalBackendReleasedOffMainRemovesObserversAndReleasesInstance() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DownloadFileStore(rootURL: root)
        try Data("audio".utf8).write(to: root.appendingPathComponent("song.mp3"))
        let player = AVPlayer()
        let center = NotificationCenter()
        let delegate = RecordingPlaybackDelegate()
        var backend: LocalPlaybackBackend? = LocalPlaybackBackend(
            fileStore: store,
            player: player,
            notificationCenter: center
        )
        backend?.delegate = delegate
        try backend?.load(downloadedTrack(id: "song"), generation: PlaybackGeneration(rawValue: 3))
        try await waitUntil { player.currentItem != nil }
        let item = try XCTUnwrap(player.currentItem)
        weak let weakBackend = backend
        let releaseBox = LockedStrongBox(backend)

        backend = nil
        releaseOffMain(releaseBox)
        center.post(name: .AVPlayerItemDidPlayToEndTime, object: item)

        XCTAssertNil(weakBackend)
        XCTAssertTrue(delegate.finishedGenerations.isEmpty)
    }

    /// 若 stop 没有释放当前 lease，本地 staging 文件会随切歌累积。
    func testLocalBackendStopReleasesPlaybackLease() async throws {
        let fixture = try LocalBackendFixture()
        try fixture.backend.load(
            fixture.track(id: "first"),
            generation: PlaybackGeneration(rawValue: 1)
        )
        // staging 文件先于 MainActor 安装 AVPlayerItem 出现；必须等 active lease 真正建立后再测 stop。
        try await waitUntil { fixture.player.currentItem != nil }
        XCTAssertEqual(try fixture.stagingFileCount(), 1)

        fixture.backend.stop()

        XCTAssertEqual(try fixture.stagingFileCount(), 0)
        XCTAssertNil(fixture.player.currentItem)
    }

    /// 同步 load/play 若等待整文件复制，会阻塞 MainActor；准备完成前也不应提前装载或播放。
    func testLocalLoadAndPlayReturnBeforeBackgroundLeasePreparationCompletes() async throws {
        let fixture = try AsyncLocalBackendFixture()
        let generation = PlaybackGeneration(rawValue: 41)

        try fixture.backend.load(fixture.track(id: "first"), generation: generation)
        fixture.backend.play()

        XCTAssertNil(fixture.player.currentItem)
        XCTAssertEqual(fixture.player.playCallCount, 0)
        try await waitUntil { fixture.provider.requestCount == 1 }

        fixture.provider.succeedRequest(at: 0)
        try await waitUntil { fixture.player.currentItem != nil }

        XCTAssertEqual(fixture.player.playCallCount, 1)
    }

    /// 换曲后第一首的后台结果必须按 generation 丢弃并立即清理 staging lease。
    func testLocalLatePreparationFromPreviousGenerationIsReleasedAndNeverLoaded() async throws {
        let fixture = try AsyncLocalBackendFixture()
        try fixture.backend.load(
            fixture.track(id: "first"),
            generation: PlaybackGeneration(rawValue: 42)
        )
        fixture.backend.play()
        try await waitUntil { fixture.provider.requestCount == 1 }

        try fixture.backend.load(
            fixture.track(id: "second"),
            generation: PlaybackGeneration(rawValue: 43)
        )
        fixture.backend.play()
        try await waitUntil { fixture.provider.requestCount == 2 }

        fixture.provider.succeedRequest(at: 0)
        try await waitUntil { fixture.provider.producedURL(at: 0) != nil }
        let staleURL = try XCTUnwrap(fixture.provider.producedURL(at: 0))
        try await waitUntil { !FileManager.default.fileExists(atPath: staleURL.path) }
        XCTAssertNil(fixture.player.currentItem)

        fixture.provider.succeedRequest(at: 1)
        try await waitUntil { fixture.player.currentItem != nil }
        let loadedURL = (fixture.player.currentItem?.asset as? AVURLAsset)?.url

        XCTAssertEqual(loadedURL, fixture.provider.producedURL(at: 1))
        XCTAssertEqual(fixture.player.playCallCount, 1)
    }

    /// stop 必须取消等待身份；不可取消的同步 provider 迟到返回时仍要释放 lease。
    func testLocalStopReleasesLeaseThatFinishesAfterCancellation() async throws {
        let fixture = try AsyncLocalBackendFixture()
        try fixture.backend.load(
            fixture.track(id: "first"),
            generation: PlaybackGeneration(rawValue: 44)
        )
        fixture.backend.play()
        try await waitUntil { fixture.provider.requestCount == 1 }

        fixture.backend.stop()
        fixture.provider.succeedRequest(at: 0)
        try await waitUntil { fixture.provider.producedURL(at: 0) != nil }
        let staleURL = try XCTUnwrap(fixture.provider.producedURL(at: 0))
        try await waitUntil { !FileManager.default.fileExists(atPath: staleURL.path) }

        XCTAssertNil(fixture.player.currentItem)
        XCTAssertEqual(fixture.player.playCallCount, 0)
    }

    /// 后台 lease 创建失败必须带原 generation 回报，供 coordinator 拒绝迟到错误。
    func testLocalPreparationFailureReportsMatchingGeneration() async throws {
        let fixture = try AsyncLocalBackendFixture()
        let generation = PlaybackGeneration(rawValue: 45)
        try fixture.backend.load(fixture.track(id: "first"), generation: generation)
        fixture.backend.play()
        try await waitUntil { fixture.provider.requestCount == 1 }

        fixture.provider.failRequest(at: 0, error: TestLeaseError.preparationFailed)
        try await waitUntil { fixture.delegate.failures.count == 1 }

        XCTAssertEqual(fixture.delegate.failures.first?.0, generation)
        XCTAssertNil(fixture.player.currentItem)
        XCTAssertEqual(fixture.player.playCallCount, 0)
    }

    private func releaseOffMain<Value>(_ box: LockedStrongBox<Value>) {
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            box.clear()
            group.leave()
        }
        XCTAssertEqual(group.wait(timeout: .now() + 2), .success)
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64 = 2_000_000_000,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while !condition() {
            guard DispatchTime.now().uptimeNanoseconds < deadline else {
                XCTFail("等待异步状态超时")
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func systemTrack(id: UInt64) -> SimpleMusic.MusicTrack {
        SimpleMusic.MusicTrack(
            id: "system-\(id)",
            title: "system",
            artist: "artist",
            album: "album",
            duration: 60,
            artworkData: nil,
            source: .system(persistentID: id)
        )
    }

    private func downloadedTrack(id: String) -> SimpleMusic.MusicTrack {
        SimpleMusic.MusicTrack(
            id: id,
            title: id,
            artist: "artist",
            album: "album",
            duration: 60,
            artworkData: nil,
            source: .downloaded(fileName: "\(id).mp3")
        )
    }
}

@MainActor
private final class SystemBackendHarness {
    let driver = FakeSystemPlaybackDriver()
    let center = NotificationCenter()
    let timer = TestPlaybackTimer()
    let delegate = RecordingPlaybackDelegate()
    let backend: SystemPlaybackBackend

    init() {
        driver.attach(notificationCenter: center)
        backend = SystemPlaybackBackend(
            driver: driver,
            notificationCenter: center,
            timerFactory: { [timer] callback in
                timer.callback = callback
                return timer
            }
        )
        backend.delegate = delegate
    }
}

@MainActor
private final class FakeSystemPlaybackDriver: NSObject, SystemPlaybackDriver {
    static let playbackStateNotification = Notification.Name("FakeSystemPlaybackState")
    static let nowPlayingItemNotification = Notification.Name("FakeSystemNowPlayingItem")

    var notificationObject: AnyObject { self }
    var playbackStateDidChangeNotification: Notification.Name { Self.playbackStateNotification }
    var nowPlayingItemDidChangeNotification: Notification.Name { Self.nowPlayingItemNotification }
    var playbackState: MPMusicPlaybackState = .stopped
    var currentPersistentID: UInt64?
    var currentPlaybackTime: TimeInterval = 0
    var currentDuration: TimeInterval = 0
    private(set) var preparedPersistentIDs = [UInt64]()
    var postsNotificationsWhenStopped = false
    var endGeneratingThreads: [Bool] { endThreadRecorder.values }
    nonisolated private let endThreadRecorder = LockedBoolArray()
    private var center: NotificationCenter?

    func attach(notificationCenter: NotificationCenter) {
        center = notificationCenter
    }

    func beginGeneratingPlaybackNotifications() {}
    nonisolated func endGeneratingPlaybackNotifications() {
        endThreadRecorder.append(Thread.isMainThread)
    }

    func prepare(persistentID: UInt64) throws {
        preparedPersistentIDs.append(persistentID)
        currentPersistentID = persistentID
        playbackState = .stopped
        currentPlaybackTime = 0
        currentDuration = 60
    }

    func play() {}
    func pause() { playbackState = .paused }
    func stop() {
        playbackState = .stopped
        guard postsNotificationsWhenStopped else { return }
        currentPersistentID = nil
        center?.post(name: Self.nowPlayingItemNotification, object: self)
        center?.post(name: Self.playbackStateNotification, object: self)
    }
    func seek(to seconds: TimeInterval) { currentPlaybackTime = seconds }

    func publishPlaying(persistentID: UInt64) {
        currentPersistentID = persistentID
        playbackState = .playing
        center?.post(name: Self.playbackStateNotification, object: self)
    }

    func publishItemChange(persistentID: UInt64?) {
        currentPersistentID = persistentID
        center?.post(name: Self.nowPlayingItemNotification, object: self)
    }

    func publishStopped() {
        playbackState = .stopped
        center?.post(name: Self.playbackStateNotification, object: self)
    }
}

@MainActor
private final class SystemObserverRecorder {
    private let driver: FakeSystemPlaybackDriver
    private var playbackStateObservers = [@MainActor @Sendable () -> Void]()
    private var itemObservers = [@MainActor @Sendable () -> Void]()

    init(driver: FakeSystemPlaybackDriver) {
        self.driver = driver
    }

    func makeObserver(
        forName name: Notification.Name,
        object: AnyObject,
        handler: @escaping @MainActor @Sendable () -> Void
    ) -> NSObjectProtocol {
        if name == driver.playbackStateDidChangeNotification {
            playbackStateObservers.append(handler)
        } else if name == driver.nowPlayingItemDidChangeNotification {
            itemObservers.append(handler)
        }
        return NSObject()
    }

    func firePlaybackStateObserver(at index: Int) {
        playbackStateObservers[index]()
    }

    func fireItemObserver(at index: Int) {
        itemObservers[index]()
    }
}

nonisolated private final class TestPlaybackTimer: PlaybackProgressTimer, @unchecked Sendable {
    private let lock = NSLock()
    private var storedCallback: (@MainActor () -> Void)?
    private var invalidated = false

    var callback: (@MainActor () -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedCallback
        }
        set {
            lock.lock()
            storedCallback = newValue
            if newValue != nil {
                invalidated = false
            }
            lock.unlock()
        }
    }

    var isInvalidated: Bool {
        lock.lock()
        defer { lock.unlock() }
        return invalidated
    }

    @MainActor
    func fire() {
        lock.lock()
        let callback = invalidated ? nil : storedCallback
        lock.unlock()
        callback?()
    }

    func invalidate() {
        lock.lock()
        invalidated = true
        storedCallback = nil
        lock.unlock()
    }
}

nonisolated private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }

    func increment() {
        lock.lock()
        storedValue += 1
        lock.unlock()
    }
}

nonisolated private final class LockedBoolArray: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValues = [Bool]()

    var values: [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return storedValues
    }

    func append(_ value: Bool) {
        lock.lock()
        storedValues.append(value)
        lock.unlock()
    }
}

nonisolated private final class LockedStrongBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value?

    init(_ value: Value) {
        self.value = value
    }

    func clear() {
        lock.lock()
        value = nil
        lock.unlock()
    }
}

@MainActor
private final class RecordingPlaybackDelegate: PlaybackBackendDelegate {
    private(set) var finishedGenerations = [PlaybackGeneration]()
    private(set) var elapsedEvents = [(PlaybackGeneration, TimeInterval, TimeInterval)]()
    private(set) var failures = [(PlaybackGeneration, Error)]()

    func playbackBackend(
        _ backend: any PlaybackBackend,
        generation: PlaybackGeneration,
        didUpdateElapsed elapsed: TimeInterval,
        duration: TimeInterval
    ) {
        elapsedEvents.append((generation, elapsed, duration))
    }

    func playbackBackendDidFinish(
        _ backend: any PlaybackBackend,
        generation: PlaybackGeneration
    ) {
        finishedGenerations.append(generation)
    }

    func playbackBackend(
        _ backend: any PlaybackBackend,
        generation: PlaybackGeneration,
        didFail error: Error
    ) {
        failures.append((generation, error))
    }
}

@MainActor
private final class LocalBackendFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let player = AVPlayer()
    let center = NotificationCenter()
    let delegate = RecordingPlaybackDelegate()
    let backend: LocalPlaybackBackend

    init() throws {
        let store = try DownloadFileStore(rootURL: root)
        try Data("first".utf8).write(to: root.appendingPathComponent("first.mp3"))
        try Data("second".utf8).write(to: root.appendingPathComponent("second.mp3"))
        backend = LocalPlaybackBackend(fileStore: store, player: player, notificationCenter: center)
        backend.delegate = delegate
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    func track(id: String) -> SimpleMusic.MusicTrack {
        SimpleMusic.MusicTrack(
            id: id,
            title: id,
            artist: "artist",
            album: "album",
            duration: 60,
            artworkData: nil,
            source: .downloaded(fileName: "\(id).mp3")
        )
    }

    func stagingFileCount() throws -> Int {
        try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix(".playback-") }
            .count
    }
}

@MainActor
private final class AsyncLocalBackendFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let player = RecordingAVPlayer()
    let delegate = RecordingPlaybackDelegate()
    let provider: ControlledPlaybackLeaseProvider
    let backend: LocalPlaybackBackend

    init() throws {
        let store = try DownloadFileStore(rootURL: root)
        try Data("first".utf8).write(to: root.appendingPathComponent("first.mp3"))
        try Data("second".utf8).write(to: root.appendingPathComponent("second.mp3"))
        let controlledProvider = ControlledPlaybackLeaseProvider(store: store)
        provider = controlledProvider
        backend = LocalPlaybackBackend(
            fileStore: store,
            player: player,
            notificationCenter: NotificationCenter(),
            leaseProvider: { fileName in
                try controlledProvider.provideLease(for: fileName)
            }
        )
        backend.delegate = delegate
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    func track(id: String) -> SimpleMusic.MusicTrack {
        SimpleMusic.MusicTrack(
            id: id,
            title: id,
            artist: "artist",
            album: "album",
            duration: 60,
            artworkData: nil,
            source: .downloaded(fileName: "\(id).mp3")
        )
    }
}

@MainActor
private final class RecordingAVPlayer: AVPlayer {
    var playCallCount: Int { playCounter.value }
    nonisolated private let playCounter = LockedCounter()

    nonisolated override func play() {
        playCounter.increment()
    }
}

nonisolated private final class ControlledPlaybackLeaseProvider: @unchecked Sendable {
    private final class Request: @unchecked Sendable {
        enum Outcome {
            case success
            case failure(Error)
        }

        let fileName: String
        let semaphore = DispatchSemaphore(value: 0)
        var outcome: Outcome?
        var producedURL: URL?

        init(fileName: String) {
            self.fileName = fileName
        }
    }

    private let store: DownloadFileStore
    private let lock = NSLock()
    private var requests = [Request]()

    init(store: DownloadFileStore) {
        self.store = store
    }

    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return requests.count
    }

    func provideLease(for fileName: String) throws -> PlaybackFileLease {
        let request = Request(fileName: fileName)
        lock.lock()
        requests.append(request)
        lock.unlock()
        request.semaphore.wait()

        lock.lock()
        let outcome = request.outcome
        lock.unlock()
        switch outcome {
        case .success:
            let lease = try store.playbackLease(for: fileName)
            lock.lock()
            request.producedURL = lease.fileURL
            lock.unlock()
            return lease
        case let .failure(error):
            throw error
        case nil:
            throw TestLeaseError.missingOutcome
        }
    }

    func succeedRequest(at index: Int) {
        completeRequest(at: index, outcome: .success)
    }

    func failRequest(at index: Int, error: Error) {
        completeRequest(at: index, outcome: .failure(error))
    }

    func producedURL(at index: Int) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        guard requests.indices.contains(index) else { return nil }
        return requests[index].producedURL
    }

    private func completeRequest(at index: Int, outcome: Request.Outcome) {
        lock.lock()
        let request = requests[index]
        request.outcome = outcome
        lock.unlock()
        request.semaphore.signal()
    }
}

private enum TestLeaseError: Error {
    case preparationFailed
    case missingOutcome
}
