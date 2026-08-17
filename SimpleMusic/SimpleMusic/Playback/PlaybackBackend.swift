import Foundation

/// 协调器选择播放实现时使用的稳定类型，不把 AVFoundation 或 MediaPlayer 对象泄漏到队列层。
enum PlaybackBackendKind: Equatable {
    case local
    case system
}

/// 后端仅上报播放事实；队列索引和界面快照统一由 `PlaybackCoordinator` 维护。
@MainActor
protocol PlaybackBackendDelegate: AnyObject {
    func playbackBackend(
        _ backend: any PlaybackBackend,
        didUpdateElapsed elapsed: TimeInterval,
        duration: TimeInterval
    )
    func playbackBackendDidFinish(_ backend: any PlaybackBackend)
    func playbackBackend(_ backend: any PlaybackBackend, didFail error: Error)
}

/// 本地与系统播放 API 的最小共同边界，每次 `load` 只承载一首歌曲。
@MainActor
protocol PlaybackBackend: AnyObject {
    var kind: PlaybackBackendKind { get }
    var delegate: (any PlaybackBackendDelegate)? { get set }
    func load(_ track: MusicTrack) throws
    func play()
    func pause()
    func stop()
    func seek(to seconds: TimeInterval)
}

enum PlaybackBackendError: Error {
    case incompatibleSource
    case systemItemNotFound(UInt64)
    case playbackFailed
}
