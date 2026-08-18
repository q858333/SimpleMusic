import AVFoundation
import Foundation

nonisolated private enum LocalLeasePreparationResult: @unchecked Sendable {
    case success(PlaybackFileLease)
    case failure(Error)
}

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
    typealias LeaseProvider = @Sendable (String) throws -> PlaybackFileLease

    private struct ActiveItem {
        let item: AVPlayerItem
        let generation: PlaybackGeneration
        let lease: PlaybackFileLease
    }

    let kind = PlaybackBackendKind.local
    weak var delegate: (any PlaybackBackendDelegate)?

    private let leaseProvider: LeaseProvider
    private let player: AVPlayer
    private let playerLifetime: LocalPlayerLifetime
    private let observationBag: NotificationObservationBag
    private var activeItem: ActiveItem?
    private var requestedGeneration: PlaybackGeneration?
    private var pendingPlay = false
    private var preparationTask: Task<Void, Never>?

    init(
        fileStore: DownloadFileStore,
        player: AVPlayer = AVPlayer(),
        notificationCenter: NotificationCenter = .default,
        leaseProvider: LeaseProvider? = nil
    ) {
        self.leaseProvider = leaseProvider ?? { fileName in
            try fileStore.playbackLease(for: fileName)
        }
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

        cancelPreparation()
        releaseActiveItem()
        requestedGeneration = generation
        pendingPlay = false

        let leaseProvider = self.leaseProvider
        let completion: @MainActor @Sendable (LocalLeasePreparationResult) -> Void = {
            [weak self] result in
            guard let self else {
                if case let .success(lease) = result {
                    lease.release()
                }
                return
            }
            self.finishPreparation(result, generation: generation)
        }
        // 整文件 staging 复制离开 MainActor；完成后只凭本次 generation 安装播放器项。
        preparationTask = Task.detached(priority: .userInitiated) {
            let result: LocalLeasePreparationResult
            do {
                result = .success(try leaseProvider(fileName))
            } catch {
                result = .failure(error)
            }
            await completion(result)
        }
    }

    func play() {
        if activeItem != nil {
            player.play()
        } else if requestedGeneration != nil {
            pendingPlay = true
        }
    }

    func pause() {
        pendingPlay = false
        player.pause()
    }

    func stop() {
        cancelPreparation()
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

    private func finishPreparation(
        _ result: LocalLeasePreparationResult,
        generation: PlaybackGeneration
    ) {
        // 取消无法打断已进入 POSIX 复制的 provider，迟到 lease 必须在这里主动释放。
        guard requestedGeneration == generation else {
            if case let .success(lease) = result {
                lease.release()
            }
            return
        }

        preparationTask = nil
        requestedGeneration = nil
        switch result {
        case let .success(lease):
            let item = AVPlayerItem(url: lease.fileURL)
            activeItem = ActiveItem(item: item, generation: generation, lease: lease)
            player.replaceCurrentItem(with: item)
            if pendingPlay {
                pendingPlay = false
                player.play()
            }
        case let .failure(error):
            pendingPlay = false
            delegate?.playbackBackend(self, generation: generation, didFail: error)
        }
    }

    private func cancelPreparation() {
        requestedGeneration = nil
        pendingPlay = false
        preparationTask?.cancel()
        preparationTask = nil
    }

    private static func finiteSeconds(_ seconds: TimeInterval) -> TimeInterval {
        seconds.isFinite ? max(0, seconds) : 0
    }
}
