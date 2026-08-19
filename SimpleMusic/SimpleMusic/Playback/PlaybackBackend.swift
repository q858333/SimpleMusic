import Foundation

/// 协调器选择播放实现时使用的稳定类型，不把 AVFoundation 或 MediaPlayer 对象泄漏到队列层。
enum PlaybackBackendKind: Equatable {
    case local
    case system
}

/// 每次 load 的不可复用身份，用于拒绝同一后端上一首遗留的异步回调。
struct PlaybackGeneration: Hashable {
    let rawValue: UInt64
}

/// 后端仅上报播放事实；队列索引和界面快照统一由 `PlaybackCoordinator` 维护。
@MainActor
protocol PlaybackBackendDelegate: AnyObject {
    func playbackBackend(
        _ backend: any PlaybackBackend,
        generation: PlaybackGeneration,
        didUpdateElapsed elapsed: TimeInterval,
        duration: TimeInterval
    )
    func playbackBackendDidFinish(
        _ backend: any PlaybackBackend,
        generation: PlaybackGeneration
    )
    func playbackBackend(
        _ backend: any PlaybackBackend,
        generation: PlaybackGeneration,
        didFail error: Error
    )
}

/// 本地与系统播放 API 的最小共同边界，每次 `load` 只承载一首歌曲。
@MainActor
protocol PlaybackBackend: AnyObject {
    var kind: PlaybackBackendKind { get }
    var delegate: (any PlaybackBackendDelegate)? { get set }
    func load(_ track: MusicTrack, generation: PlaybackGeneration) throws
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

/// NotificationCenter 的 token 可跨线程移除；holder 让后端析构不依赖 MainActor deinit。
nonisolated final class NotificationObservationBag: @unchecked Sendable {
    private let notificationCenter: NotificationCenter
    private let lock = NSLock()
    private var tokens = [NSObjectProtocol]()

    init(notificationCenter: NotificationCenter) {
        self.notificationCenter = notificationCenter
    }

    func insert(_ token: NSObjectProtocol) {
        lock.lock()
        tokens.append(token)
        lock.unlock()
    }

    func removeAll() {
        lock.lock()
        let tokens = self.tokens
        self.tokens.removeAll()
        lock.unlock()
        tokens.forEach(notificationCenter.removeObserver)
    }

    deinit {
        removeAll()
    }
}
