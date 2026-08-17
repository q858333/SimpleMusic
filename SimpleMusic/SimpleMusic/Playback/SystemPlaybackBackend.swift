import Foundation
import MediaPlayer

/// 将持久 ID 解析限制在 `MusicLibraryService` 主线程边界，并以单项系统队列播放。
@MainActor
final class SystemPlaybackBackend: NSObject, PlaybackBackend {
    let kind = PlaybackBackendKind.system
    weak var delegate: (any PlaybackBackendDelegate)?

    private let libraryService: MusicLibraryService
    private let player: MPMusicPlayerController
    private var progressTimer: Timer?
    private var observedPlaying = false

    init(
        libraryService: MusicLibraryService,
        player: MPMusicPlayerController = .applicationMusicPlayer
    ) {
        self.libraryService = libraryService
        self.player = player
        super.init()
        player.beginGeneratingPlaybackNotifications()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(playbackStateDidChange),
            name: .MPMusicPlayerControllerPlaybackStateDidChange,
            object: player
        )
    }

    deinit {
        progressTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
        player.endGeneratingPlaybackNotifications()
    }

    func load(_ track: MusicTrack) throws {
        guard case let .system(persistentID) = track.source else {
            throw PlaybackBackendError.incompatibleSource
        }
        guard let item = libraryService.mediaItem(for: persistentID) else {
            throw PlaybackBackendError.systemItemNotFound(persistentID)
        }
        observedPlaying = false
        progressTimer?.invalidate()
        progressTimer = nil
        player.setQueue(with: MPMediaItemCollection(items: [item]))
    }

    func play() {
        player.play()
        startProgressTimer()
    }

    func pause() {
        player.pause()
        progressTimer?.invalidate()
        progressTimer = nil
    }

    func stop() {
        observedPlaying = false
        progressTimer?.invalidate()
        progressTimer = nil
        player.stop()
    }

    func seek(to seconds: TimeInterval) {
        player.currentPlaybackTime = max(0, seconds)
    }

    @objc private func publishProgress() {
        let duration = player.nowPlayingItem?.playbackDuration ?? 0
        delegate?.playbackBackend(
            self,
            didUpdateElapsed: max(0, player.currentPlaybackTime),
            duration: max(0, duration)
        )
    }

    @objc private func playbackStateDidChange() {
        switch player.playbackState {
        case .playing:
            observedPlaying = true
        case .stopped where observedPlaying:
            // 仅把真实的 playing→stopped 视为自然结束；显式 stop 会先清除此标记。
            observedPlaying = false
            progressTimer?.invalidate()
            progressTimer = nil
            delegate?.playbackBackendDidFinish(self)
        default:
            break
        }
    }

    private func startProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(
            timeInterval: 0.5,
            target: self,
            selector: #selector(publishProgress),
            userInfo: nil,
            repeats: true
        )
    }
}
