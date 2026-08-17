import AVFoundation
import Foundation

/// AVPlayer API 可跨队列控制；holder 在非隔离析构中幂等停止并移除 time observer。
nonisolated private final class LocalPlayerLifetime: @unchecked Sendable {
    let player: AVPlayer
    private let lock = NSLock()
    private var timeObserver: Any?
    private var isTornDown = false

    init(player: AVPlayer) {
        self.player = player
    }

    func setTimeObserver(_ timeObserver: Any) {
        lock.lock()
        self.timeObserver = timeObserver
        lock.unlock()
    }

    func teardown() {
        lock.lock()
        guard !isTornDown else {
            lock.unlock()
            return
        }
        isTornDown = true
        let timeObserver = self.timeObserver
        self.timeObserver = nil
        lock.unlock()

        player.pause()
        player.replaceCurrentItem(with: nil)
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
    }

    deinit {
        teardown()
    }
}

/// 使用受控文件 lease 创建 AVPlayerItem，并把主队列系统回调按 generation 转发给协调器。
@MainActor
final class LocalPlaybackBackend: NSObject, PlaybackBackend {
    private struct ActiveItem {
        let item: AVPlayerItem
        let generation: PlaybackGeneration
        let lease: PlaybackFileLease
    }

    let kind = PlaybackBackendKind.local
    weak var delegate: (any PlaybackBackendDelegate)?

    private let fileStore: DownloadFileStore
    private let player: AVPlayer
    private let playerLifetime: LocalPlayerLifetime
    private let observationBag: NotificationObservationBag
    private var activeItem: ActiveItem?

    init(
        fileStore: DownloadFileStore,
        player: AVPlayer = AVPlayer(),
        notificationCenter: NotificationCenter = .default
    ) {
        self.fileStore = fileStore
        self.player = player
        playerLifetime = LocalPlayerLifetime(player: player)
        observationBag = NotificationObservationBag(notificationCenter: notificationCenter)
        super.init()

        observationBag.insert(notificationCenter.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                self?.itemDidFinish(notification)
            }
        })
        observationBag.insert(notificationCenter.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                self?.itemDidFail(notification)
            }
        })
        let timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.publishProgress()
            }
        }
        playerLifetime.setTimeObserver(timeObserver)
    }

    func load(_ track: MusicTrack, generation: PlaybackGeneration) throws {
        guard case let .downloaded(fileName) = track.source else {
            throw PlaybackBackendError.incompatibleSource
        }

        releaseActiveItem()
        let lease = try fileStore.playbackLease(for: fileName)
        let item = AVPlayerItem(url: lease.fileURL)
        activeItem = ActiveItem(item: item, generation: generation, lease: lease)
        player.replaceCurrentItem(with: item)
    }

    func play() {
        player.play()
    }

    func pause() {
        player.pause()
    }

    func stop() {
        player.pause()
        releaseActiveItem()
    }

    func seek(to seconds: TimeInterval) {
        player.seek(to: CMTime(seconds: max(0, seconds), preferredTimescale: 600))
    }

    private func itemDidFinish(_ notification: Notification) {
        guard let activeItem,
              notification.object as AnyObject? === activeItem.item else { return }
        delegate?.playbackBackendDidFinish(self, generation: activeItem.generation)
    }

    private func itemDidFail(_ notification: Notification) {
        guard let activeItem,
              notification.object as AnyObject? === activeItem.item else { return }
        let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            ?? PlaybackBackendError.playbackFailed
        delegate?.playbackBackend(self, generation: activeItem.generation, didFail: error)
    }

    private func publishProgress() {
        guard let activeItem, player.currentItem === activeItem.item else { return }
        let elapsed = Self.finiteSeconds(player.currentTime().seconds)
        let duration = Self.finiteSeconds(activeItem.item.duration.seconds)
        delegate?.playbackBackend(
            self,
            generation: activeItem.generation,
            didUpdateElapsed: elapsed,
            duration: duration
        )
    }

    private func releaseActiveItem() {
        let lease = activeItem?.lease
        activeItem = nil
        player.replaceCurrentItem(with: nil)
        lease?.release()
    }

    private static func finiteSeconds(_ seconds: TimeInterval) -> TimeInterval {
        seconds.isFinite ? max(0, seconds) : 0
    }
}
