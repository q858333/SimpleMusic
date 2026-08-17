import AVFoundation
import MediaPlayer
import XCTest
@testable import SimpleMusic

@MainActor
final class PlaybackBackendLifecycleTests: XCTestCase {
    /// 若外部 stop 仅凭 stopped + nil item 被判为结束，协调器会擅自 next。
    func testSystemBackendDoesNotFinishForExternalStopBeforeRealEnd() throws {
        let harness = SystemBackendHarness()
        let generation = PlaybackGeneration(rawValue: 1)
        try harness.backend.load(systemTrack(id: 11), generation: generation)
        harness.backend.play()
        harness.driver.publishPlaying(persistentID: 11)
        harness.driver.currentPlaybackTime = 10
        harness.driver.currentDuration = 60
        harness.timer.fire()

        harness.driver.publishItemChange(persistentID: nil)
        harness.driver.publishStopped()

        XCTAssertTrue(harness.delegate.finishedGenerations.isEmpty)
    }

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

    /// stopped 可能早于 item-nil 通知；同一 generation 的证据应独立记录后再联合完成。
    func testSystemBackendFinishesWhenStoppedArrivesBeforeItemRemoval() throws {
        let harness = SystemBackendHarness()
        let generation = PlaybackGeneration(rawValue: 3)
        try harness.backend.load(systemTrack(id: 33), generation: generation)
        harness.backend.play()
        harness.driver.publishPlaying(persistentID: 33)
        harness.driver.currentPlaybackTime = 60
        harness.driver.currentDuration = 60

        harness.driver.publishStopped()
        XCTAssertTrue(harness.delegate.finishedGenerations.isEmpty)
        harness.driver.publishItemChange(persistentID: nil)

        XCTAssertEqual(harness.delegate.finishedGenerations, [generation])
    }

    /// 若真实末尾的 item-nil 与 stopped 证据不能联合完成当前 generation，队列不会自动推进。
    func testSystemBackendFinishesCurrentGenerationAtRealTrackEnd() throws {
        let harness = SystemBackendHarness()
        let generation = PlaybackGeneration(rawValue: 9)
        try harness.backend.load(systemTrack(id: 99), generation: generation)
        harness.backend.play()
        harness.driver.publishPlaying(persistentID: 99)
        harness.driver.currentPlaybackTime = 59.8
        harness.driver.currentDuration = 60
        harness.timer.fire()

        harness.driver.publishItemChange(persistentID: nil)
        harness.driver.publishStopped()

        XCTAssertEqual(harness.delegate.finishedGenerations, [generation])
    }

    /// 若 Timer/observer 强持有后端，释放后不会 teardown 系统通知生成和计时器。
    func testSystemBackendReleasedOffMainInvalidatesTimerAndRemovesObservers() throws {
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
        driver.publishPlaying(persistentID: 44)
        driver.publishItemChange(persistentID: nil)
        driver.publishStopped()

        XCTAssertNil(weakBackend)
        XCTAssertTrue(timer.isInvalidated)
        XCTAssertEqual(driver.endGeneratingCount, 1)
        XCTAssertTrue(delegate.finishedGenerations.isEmpty)
    }

    /// 若本地后端只按 backend 过滤通知，上一 AVPlayerItem 的迟到完成会结束新曲。
    func testLocalBackendIgnoresLateFinishFromPreviousItem() throws {
        let fixture = try LocalBackendFixture()
        let firstGeneration = PlaybackGeneration(rawValue: 1)
        let secondGeneration = PlaybackGeneration(rawValue: 2)
        try fixture.backend.load(fixture.track(id: "first"), generation: firstGeneration)
        let firstItem = try XCTUnwrap(fixture.player.currentItem)
        try fixture.backend.load(fixture.track(id: "second"), generation: secondGeneration)
        let secondItem = try XCTUnwrap(fixture.player.currentItem)

        fixture.center.post(name: .AVPlayerItemDidPlayToEndTime, object: firstItem)
        XCTAssertTrue(fixture.delegate.finishedGenerations.isEmpty)
        fixture.center.post(name: .AVPlayerItemDidPlayToEndTime, object: secondItem)

        XCTAssertEqual(fixture.delegate.finishedGenerations, [secondGeneration])
    }

    /// 若本地 observer/time observer 形成保留或未移除，后端释放后仍会响应迟到通知。
    func testLocalBackendReleasedOffMainRemovesObserversAndReleasesInstance() throws {
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
    func testLocalBackendStopReleasesPlaybackLease() throws {
        let fixture = try LocalBackendFixture()
        try fixture.backend.load(
            fixture.track(id: "first"),
            generation: PlaybackGeneration(rawValue: 1)
        )
        XCTAssertEqual(try fixture.stagingFileCount(), 1)

        fixture.backend.stop()

        XCTAssertEqual(try fixture.stagingFileCount(), 0)
        XCTAssertNil(fixture.player.currentItem)
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
    var endGeneratingCount: Int { endGeneratingCounter.value }
    nonisolated private let endGeneratingCounter = LockedCounter()
    private var center: NotificationCenter?

    func attach(notificationCenter: NotificationCenter) {
        center = notificationCenter
    }

    func beginGeneratingPlaybackNotifications() {}
    nonisolated func endGeneratingPlaybackNotifications() {
        endGeneratingCounter.increment()
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
