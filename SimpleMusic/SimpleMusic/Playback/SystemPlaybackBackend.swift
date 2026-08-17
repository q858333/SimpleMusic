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
    nonisolated func endGeneratingPlaybackNotifications()
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

/// 系统通知生成必须与后端同寿命；end 是线程安全且恰好一次的系统清理边界。
nonisolated private final class SystemNotificationGenerationOwner: @unchecked Sendable {
    private let driver: any SystemPlaybackDriver
    private let lock = NSLock()
    private var hasEnded = false

    init(driver: any SystemPlaybackDriver) {
        self.driver = driver
    }

    func end() {
        lock.lock()
        guard !hasEnded else {
            lock.unlock()
            return
        }
        hasEnded = true
        lock.unlock()
        driver.endGeneratingPlaybackNotifications()
    }

    deinit {
        end()
    }
}

@MainActor
private final class MPMusicPlayerDriver: SystemPlaybackDriver {
    let libraryService: MusicLibraryService
    nonisolated(unsafe) let player: MPMusicPlayerController

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

    nonisolated func endGeneratingPlaybackNotifications() {
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

    private struct ActivePlayback {
        let persistentID: UInt64
        let generation: PlaybackGeneration
        var observedPlaying = false
        var reachedTrackEnd = false
        var observedItemRemoval = false
        var observedStopped = false
    }

    let kind = PlaybackBackendKind.system
    weak var delegate: (any PlaybackBackendDelegate)?

    private let driver: any SystemPlaybackDriver
    private let timerFactory: TimerFactory
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
        }
    ) {
        self.driver = driver
        self.timerFactory = timerFactory
        observationBag = NotificationObservationBag(notificationCenter: notificationCenter)
        notificationGenerationOwner = SystemNotificationGenerationOwner(driver: driver)
        super.init()

        driver.beginGeneratingPlaybackNotifications()
        observationBag.insert(notificationCenter.addObserver(
            forName: driver.playbackStateDidChangeNotification,
            object: driver.notificationObject,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.playbackStateDidChange()
            }
        })
        observationBag.insert(notificationCenter.addObserver(
            forName: driver.nowPlayingItemDidChangeNotification,
            object: driver.notificationObject,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.nowPlayingItemDidChange()
            }
        })
    }

    func load(_ track: MusicTrack, generation: PlaybackGeneration) throws {
        guard case let .system(persistentID) = track.source else {
            throw PlaybackBackendError.incompatibleSource
        }

        invalidateProgressTimer()
        activePlayback = nil
        try driver.prepare(persistentID: persistentID)
        activePlayback = ActivePlayback(persistentID: persistentID, generation: generation)
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
        driver.stop()
    }

    func seek(to seconds: TimeInterval) {
        driver.seek(to: max(0, seconds))
    }

    private func publishProgress() {
        guard var activePlayback,
              driver.currentPersistentID == activePlayback.persistentID else { return }
        let elapsed = Self.finiteSeconds(driver.currentPlaybackTime)
        let duration = Self.finiteSeconds(driver.currentDuration)
        if Self.isAtTrackEnd(elapsed: elapsed, duration: duration) {
            activePlayback.reachedTrackEnd = true
        } else {
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

    private func playbackStateDidChange() {
        guard var activePlayback else { return }
        switch driver.playbackState {
        case .playing where driver.currentPersistentID == activePlayback.persistentID:
            activePlayback.observedPlaying = true
            if !activePlayback.reachedTrackEnd {
                activePlayback.observedItemRemoval = false
                activePlayback.observedStopped = false
            }
        case .stopped where activePlayback.observedPlaying
            && (driver.currentPersistentID == activePlayback.persistentID
                || driver.currentPersistentID == nil):
            updateEndEvidence(&activePlayback)
            activePlayback.observedStopped = true
        default:
            break
        }
        self.activePlayback = activePlayback
        finishIfEvidenceIsComplete()
    }

    private func nowPlayingItemDidChange() {
        guard var activePlayback,
              activePlayback.observedPlaying,
              driver.currentPersistentID == nil else { return }
        updateEndEvidence(&activePlayback)
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
        delegate?.playbackBackendDidFinish(self, generation: activePlayback.generation)
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

    private func updateEndEvidence(_ activePlayback: inout ActivePlayback) {
        let elapsed = Self.finiteSeconds(driver.currentPlaybackTime)
        let duration = Self.finiteSeconds(driver.currentDuration)
        if Self.isAtTrackEnd(elapsed: elapsed, duration: duration) {
            activePlayback.reachedTrackEnd = true
        }
    }

    private static func isAtTrackEnd(elapsed: TimeInterval, duration: TimeInterval) -> Bool {
        duration > 0 && elapsed >= max(0, duration - 0.5)
    }

    private static func finiteSeconds(_ seconds: TimeInterval) -> TimeInterval {
        seconds.isFinite ? max(0, seconds) : 0
    }
}
