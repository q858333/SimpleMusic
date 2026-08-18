import Foundation
import MediaPlayer

/// 系统播放器的可替换 API 边界；真实 adapter 仍以单项 MPMediaItemCollection 设置队列。
@MainActor
protocol SystemPlaybackDriver: AnyObject {
    var notificationObject: AnyObject { get }
    var playbackStateDidChangeNotification: Notification.Name { get }
    var nowPlayingItemDidChangeNotification: Notification.Name { get }
    var playbackState: MPMusicPlaybackState { get }
    var currentPersistentID: UInt64? { get }
    var currentPlaybackTime: TimeInterval { get }
    var currentDuration: TimeInterval { get }
    func beginGeneratingPlaybackNotifications()
    func endGeneratingPlaybackNotifications()
    func prepare(persistentID: UInt64) throws
    func play()
    func pause()
    func stop()
    func seek(to seconds: TimeInterval)
}

/// 系统计时器的最小生命周期边界，便于验证 invalidate 与释放行为。
nonisolated protocol PlaybackProgressTimer: AnyObject {
    func invalidate()
}

/// 无论 timer 是否还被测试或 RunLoop 持有，owner 析构都会幂等 invalidate。
nonisolated private final class PlaybackProgressTimerOwner: @unchecked Sendable {
    private let lock = NSLock()
    private var timer: (any PlaybackProgressTimer)?

    func replace(with timer: any PlaybackProgressTimer) {
        lock.lock()
        let oldTimer = self.timer
        self.timer = timer
        lock.unlock()
        oldTimer?.invalidate()
    }

    func invalidate() {
        lock.lock()
        let timer = self.timer
        self.timer = nil
        lock.unlock()
        timer?.invalidate()
    }

    deinit {
        invalidate()
    }
}

/// framework begin/end 始终在 MainActor；析构只负责把兜底清理调度回 MainActor。
nonisolated private final class SystemNotificationGenerationOwner: @unchecked Sendable {
    private let driver: any SystemPlaybackDriver
    private let lock = NSLock()
    private var isGenerating = false

    init(driver: any SystemPlaybackDriver) {
        self.driver = driver
    }

    @MainActor
    func beginIfNeeded() {
        lock.lock()
        guard !isGenerating else {
            lock.unlock()
            return
        }
        isGenerating = true
        lock.unlock()
        driver.beginGeneratingPlaybackNotifications()
    }

    @MainActor
    func shutdown() {
        guard takeGeneratingState() else { return }
        driver.endGeneratingPlaybackNotifications()
    }

    deinit {
        guard takeGeneratingState() else { return }
        let driver = self.driver
        Task { @MainActor in
            driver.endGeneratingPlaybackNotifications()
        }
    }

    private func takeGeneratingState() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard isGenerating else { return false }
        isGenerating = false
        return true
    }
}

@MainActor
private final class MPMusicPlayerDriver: SystemPlaybackDriver {
    let libraryService: MusicLibraryService
    let player: MPMusicPlayerController

    var notificationObject: AnyObject { player }
    var playbackStateDidChangeNotification: Notification.Name {
        .MPMusicPlayerControllerPlaybackStateDidChange
    }
    var nowPlayingItemDidChangeNotification: Notification.Name {
        .MPMusicPlayerControllerNowPlayingItemDidChange
    }
    var playbackState: MPMusicPlaybackState { player.playbackState }
    var currentPersistentID: UInt64? { player.nowPlayingItem?.persistentID }
    var currentPlaybackTime: TimeInterval { player.currentPlaybackTime }
    var currentDuration: TimeInterval { player.nowPlayingItem?.playbackDuration ?? 0 }

    init(libraryService: MusicLibraryService, player: MPMusicPlayerController) {
        self.libraryService = libraryService
        self.player = player
    }

    func beginGeneratingPlaybackNotifications() {
        player.beginGeneratingPlaybackNotifications()
    }

    func endGeneratingPlaybackNotifications() {
        player.endGeneratingPlaybackNotifications()
    }

    func prepare(persistentID: UInt64) throws {
        guard let item = libraryService.mediaItem(for: persistentID) else {
            throw PlaybackBackendError.systemItemNotFound(persistentID)
        }
        player.setQueue(with: MPMediaItemCollection(items: [item]))
    }

    func play() { player.play() }
    func pause() { player.pause() }
    func stop() { player.stop() }
    func seek(to seconds: TimeInterval) { player.currentPlaybackTime = seconds }
}

nonisolated private final class FoundationPlaybackProgressTimer: PlaybackProgressTimer, @unchecked Sendable {
    private var timer: Timer?

    @MainActor
    init(callback: @escaping @MainActor () -> Void) {
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            MainActor.assumeIsolated {
                callback()
            }
        }
    }

    func invalidate() {
        timer?.invalidate()
        timer = nil
    }

    deinit {
        timer?.invalidate()
    }
}

/// 将 persistentID、generation 与真实末尾证据绑定，再向协调器上报系统播放完成。
@MainActor
final class SystemPlaybackBackend: NSObject, PlaybackBackend {
    typealias TimerFactory = @MainActor (@escaping @MainActor () -> Void) -> any PlaybackProgressTimer
    typealias ObserverFactory = @MainActor (
        Notification.Name,
        AnyObject,
        @escaping @MainActor () -> Void
    ) -> NSObjectProtocol

    private struct ActivePlayback {
        let persistentID: UInt64
        let generation: PlaybackGeneration
        let loadedDuration: TimeInterval
        var lastElapsed: TimeInterval = 0
        var observedPlaying = false
        var reachedTrackEnd = false
        var observedItemRemoval = false
        var observedStopped = false
    }

    let kind = PlaybackBackendKind.system
    weak var delegate: (any PlaybackBackendDelegate)?

    private let driver: any SystemPlaybackDriver
    private let timerFactory: TimerFactory
    private let observerFactory: ObserverFactory
    private let observationBag: NotificationObservationBag
    private let timerOwner = PlaybackProgressTimerOwner()
    private let notificationGenerationOwner: SystemNotificationGenerationOwner
    private var activePlayback: ActivePlayback?

    convenience init(
        libraryService: MusicLibraryService,
        player: MPMusicPlayerController = .applicationMusicPlayer
    ) {
        self.init(driver: MPMusicPlayerDriver(libraryService: libraryService, player: player))
    }

    init(
        driver: any SystemPlaybackDriver,
        notificationCenter: NotificationCenter = .default,
        timerFactory: @escaping TimerFactory = { callback in
            FoundationPlaybackProgressTimer(callback: callback)
        },
        observerFactory: ObserverFactory? = nil
    ) {
        self.driver = driver
        self.timerFactory = timerFactory
        self.observerFactory = observerFactory ?? { name, object, handler in
            notificationCenter.addObserver(
                forName: name,
                object: object,
                queue: .main
            ) { _ in
                MainActor.assumeIsolated {
                    handler()
                }
            }
        }
        observationBag = NotificationObservationBag(notificationCenter: notificationCenter)
        notificationGenerationOwner = SystemNotificationGenerationOwner(driver: driver)
        super.init()
    }

    func load(_ track: MusicTrack, generation: PlaybackGeneration) throws {
        guard case let .system(persistentID) = track.source else {
            throw PlaybackBackendError.incompatibleSource
        }

        invalidateProgressTimer()
        activePlayback = nil
        observationBag.removeAll()
        try driver.prepare(persistentID: persistentID)
        activePlayback = ActivePlayback(
            persistentID: persistentID,
            generation: generation,
            loadedDuration: Self.finiteSeconds(track.duration)
        )
        notificationGenerationOwner.beginIfNeeded()
        bindObservers(generation: generation, persistentID: persistentID)
    }

    func play() {
        guard activePlayback != nil else { return }
        driver.play()
        startProgressTimer()
    }

    func pause() {
        driver.pause()
        invalidateProgressTimer()
    }

    func stop() {
        // 先失效身份，再触发系统 stopped 通知，显式停止永远不会被识别为自然结束。
        activePlayback = nil
        invalidateProgressTimer()
        observationBag.removeAll()
        driver.stop()
        notificationGenerationOwner.shutdown()
    }

    func seek(to seconds: TimeInterval) {
        let target = max(0, seconds)
        if var activePlayback {
            let driverDuration = Self.finiteSeconds(driver.currentDuration)
            let duration = driverDuration > 0 ? driverDuration : activePlayback.loadedDuration
            if !Self.isAtTrackEnd(elapsed: target, duration: duration) {
                activePlayback.lastElapsed = target
                clearEndEvidence(&activePlayback)
                self.activePlayback = activePlayback
            }
        }
        driver.seek(to: target)
    }

    private func publishProgress() {
        guard var activePlayback,
              driver.currentPersistentID == activePlayback.persistentID else { return }
        let elapsed = Self.finiteSeconds(driver.currentPlaybackTime)
        let duration = Self.finiteSeconds(driver.currentDuration)
        activePlayback.lastElapsed = elapsed
        activePlayback.reachedTrackEnd = Self.isAtTrackEnd(elapsed: elapsed, duration: duration)
        if !activePlayback.reachedTrackEnd {
            // stopped 后仍有当前 persistentID 的中段进度，说明该通知属于旧播放实例。
            activePlayback.observedItemRemoval = false
            activePlayback.observedStopped = false
        }
        self.activePlayback = activePlayback
        delegate?.playbackBackend(
            self,
            generation: activePlayback.generation,
            didUpdateElapsed: elapsed,
            duration: duration
        )
    }

    private func playbackStateDidChange(
        generation: PlaybackGeneration,
        persistentID: UInt64
    ) {
        guard var activePlayback,
              activePlayback.generation == generation,
              activePlayback.persistentID == persistentID else { return }
        switch driver.playbackState {
        case .playing where driver.currentPersistentID == activePlayback.persistentID:
            activePlayback.observedPlaying = true
            activePlayback.observedItemRemoval = false
            activePlayback.observedStopped = false
        case .stopped where activePlayback.observedPlaying
            && (driver.currentPersistentID == activePlayback.persistentID
                || driver.currentPersistentID == nil):
            activePlayback.observedStopped = true
        default:
            break
        }
        self.activePlayback = activePlayback
        finishIfEvidenceIsComplete()
    }

    private func nowPlayingItemDidChange(
        generation: PlaybackGeneration,
        persistentID: UInt64
    ) {
        guard var activePlayback,
              activePlayback.generation == generation,
              activePlayback.persistentID == persistentID,
              activePlayback.observedPlaying,
              driver.currentPersistentID == nil else { return }
        activePlayback.observedItemRemoval = true
        self.activePlayback = activePlayback
        finishIfEvidenceIsComplete()
    }

    private func finishIfEvidenceIsComplete() {
        guard let activePlayback,
              activePlayback.observedPlaying,
              activePlayback.reachedTrackEnd,
              activePlayback.observedItemRemoval,
              activePlayback.observedStopped,
              driver.currentPersistentID == nil else { return }

        self.activePlayback = nil
        invalidateProgressTimer()
        observationBag.removeAll()
        delegate?.playbackBackendDidFinish(self, generation: activePlayback.generation)
    }

    private func bindObservers(generation: PlaybackGeneration, persistentID: UInt64) {
        // 每次 load 都重建 token；已排队的旧 block 仍携带旧身份，因此无法拼接完成证据。
        observationBag.insert(observerFactory(
            driver.playbackStateDidChangeNotification,
            driver.notificationObject
        ) { [weak self] in
            self?.playbackStateDidChange(generation: generation, persistentID: persistentID)
        })
        observationBag.insert(observerFactory(
            driver.nowPlayingItemDidChangeNotification,
            driver.notificationObject
        ) { [weak self] in
            self?.nowPlayingItemDidChange(generation: generation, persistentID: persistentID)
        })
    }

    private func startProgressTimer() {
        invalidateProgressTimer()
        let timer = timerFactory { [weak self] in
            self?.publishProgress()
        }
        timerOwner.replace(with: timer)
    }

    private func invalidateProgressTimer() {
        timerOwner.invalidate()
    }

    private func clearEndEvidence(_ activePlayback: inout ActivePlayback) {
        activePlayback.reachedTrackEnd = false
        activePlayback.observedItemRemoval = false
        activePlayback.observedStopped = false
    }

    private static func isAtTrackEnd(elapsed: TimeInterval, duration: TimeInterval) -> Bool {
        // 0.5 秒进度周期外再容纳一次调度抖动，避免末次 timer 未正好落在 duration 上。
        duration > 0 && elapsed >= max(0, duration - 1)
    }

    private static func finiteSeconds(_ seconds: TimeInterval) -> TimeInterval {
        seconds.isFinite ? max(0, seconds) : 0
    }
}
