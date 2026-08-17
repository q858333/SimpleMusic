import AVFoundation
import Foundation

/// 使用 `DownloadFileStore` 的安全文件边界创建 AVPlayerItem，并把系统回调转发给协调器。
@MainActor
final class LocalPlaybackBackend: NSObject, PlaybackBackend {
    let kind = PlaybackBackendKind.local
    weak var delegate: (any PlaybackBackendDelegate)?

    private let fileStore: DownloadFileStore
    private let player: AVPlayer
    private var timeObserver: Any?

    init(fileStore: DownloadFileStore, player: AVPlayer = AVPlayer()) {
        self.fileStore = fileStore
        self.player = player
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(itemDidFinish(_:)),
            name: .AVPlayerItemDidPlayToEndTime,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(itemDidFail(_:)),
            name: .AVPlayerItemFailedToPlayToEndTime,
            object: nil
        )
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let duration = self.player.currentItem?.duration.seconds ?? 0
                self.delegate?.playbackBackend(
                    self,
                    didUpdateElapsed: Self.finiteSeconds(time.seconds),
                    duration: Self.finiteSeconds(duration)
                )
            }
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
    }

    func load(_ track: MusicTrack) throws {
        guard case let .downloaded(fileName) = track.source else {
            throw PlaybackBackendError.incompatibleSource
        }
        let fileURL = try fileStore.fileURL(for: fileName)
        player.replaceCurrentItem(with: AVPlayerItem(url: fileURL))
    }

    func play() {
        player.play()
    }

    func pause() {
        player.pause()
    }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
    }

    func seek(to seconds: TimeInterval) {
        player.seek(to: CMTime(seconds: max(0, seconds), preferredTimescale: 600))
    }

    @objc private func itemDidFinish(_ notification: Notification) {
        guard notification.object as AnyObject? === player.currentItem else { return }
        delegate?.playbackBackendDidFinish(self)
    }

    @objc private func itemDidFail(_ notification: Notification) {
        guard notification.object as AnyObject? === player.currentItem else { return }
        let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            ?? PlaybackBackendError.playbackFailed
        delegate?.playbackBackend(self, didFail: error)
    }

    private static func finiteSeconds(_ seconds: TimeInterval) -> TimeInterval {
        seconds.isFinite ? max(0, seconds) : 0
    }
}
