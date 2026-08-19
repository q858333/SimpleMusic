import AVFAudio
import Combine
import Foundation
import MediaPlayer
import UIKit

nonisolated enum RemotePlaybackCommand: CaseIterable, Hashable, Sendable {
    case play
    case pause
    case next
    case previous
    case changePlaybackPosition
}

nonisolated enum RemoteCommandPayload: Sendable {
    case none
    case position(TimeInterval)
}

typealias RemoteCommandHandler = @Sendable (
    RemoteCommandPayload
) -> MPRemoteCommandHandlerStatus

nonisolated private enum RemoteCommandPlaybackState: Sendable {
    case idle
    case loading
    case playing
    case paused
    case failed
}

/// 每次 start 使用新的引用身份，避免计数器回绕让陈旧注册重新生效。
nonisolated private final class RemoteCommandGeneration: @unchecked Sendable {}

nonisolated private struct RemoteCommandDecision: Sendable {
    let status: MPRemoteCommandHandlerStatus
    let actionGeneration: RemoteCommandGeneration?
}

/// 后台 MediaPlayer 回调只能在锁内读取这份值状态，绝不触碰 MainActor 播放器对象。
nonisolated private final class RemoteCommandStateCache: @unchecked Sendable {
    private struct State {
        var isStarted = false
        var generation: RemoteCommandGeneration?
        var playbackState = RemoteCommandPlaybackState.idle
        var hasTrack = false
        var queueIndex: Int?
        var queueCount = 0
    }

    private let lock = NSLock()
    private var state = State()

    func start(generation: RemoteCommandGeneration) {
        withLock {
            $0 = State(isStarted: true, generation: generation)
        }
    }

    func stop() {
        withLock {
            $0 = State()
        }
    }

    func update(
        playbackState: RemoteCommandPlaybackState,
        hasTrack: Bool,
        queueIndex: Int?,
        queueCount: Int
    ) {
        withLock {
            guard $0.isStarted else { return }
            $0.playbackState = playbackState
            $0.hasTrack = hasTrack
            $0.queueIndex = queueIndex
            $0.queueCount = queueCount
        }
    }

    func decision(
        for command: RemotePlaybackCommand,
        payload: RemoteCommandPayload,
        expectedGeneration: RemoteCommandGeneration
    ) -> RemoteCommandDecision {
        withLock { state in
            guard state.isStarted,
                  let currentGeneration = state.generation,
                  currentGeneration === expectedGeneration else {
                return RemoteCommandDecision(status: .commandFailed, actionGeneration: nil)
            }

            switch command {
            case .play:
                guard state.hasTrack, state.playbackState != .idle else {
                    return RemoteCommandDecision(status: .noSuchContent, actionGeneration: nil)
                }
                if state.playbackState == .playing {
                    return RemoteCommandDecision(status: .success, actionGeneration: nil)
                }
                guard state.playbackState == .paused else {
                    return RemoteCommandDecision(status: .commandFailed, actionGeneration: nil)
                }
            case .pause:
                guard state.hasTrack, state.playbackState != .idle else {
                    return RemoteCommandDecision(status: .noSuchContent, actionGeneration: nil)
                }
                if state.playbackState == .paused {
                    return RemoteCommandDecision(status: .success, actionGeneration: nil)
                }
                guard state.playbackState == .playing else {
                    return RemoteCommandDecision(status: .commandFailed, actionGeneration: nil)
                }
            case .next, .previous:
                guard state.hasTrack,
                      state.playbackState != .idle,
                      state.queueIndex != nil,
                      state.queueCount > 0 else {
                    return RemoteCommandDecision(status: .noSuchContent, actionGeneration: nil)
                }
            case .changePlaybackPosition:
                guard case let .position(position) = payload,
                      position.isFinite,
                      position >= 0,
                      state.hasTrack,
                      state.playbackState == .playing || state.playbackState == .paused else {
                    return RemoteCommandDecision(status: .commandFailed, actionGeneration: nil)
                }
            }

            return RemoteCommandDecision(status: .success, actionGeneration: currentGeneration)
        }
    }

    private func withLock<Result>(_ body: (inout State) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&state)
    }
}

/// 隔离 MPRemoteCommandCenter 的 target 生命周期，使注册和清理可独立验证。
@MainActor
protocol RemoteCommandRegistering: AnyObject {
    func addTarget(
        for command: RemotePlaybackCommand,
        handler: @escaping RemoteCommandHandler
    ) -> AnyObject

    func removeTarget(_ token: AnyObject, for command: RemotePlaybackCommand)
}

/// 隔离系统锁屏信息中心，测试只验证本服务生成的媒体信息。
@MainActor
protocol NowPlayingInfoWriting: AnyObject {
    var nowPlayingInfo: [String: Any]? { get set }
}

/// 隔离会抛错的 AVAudioSession 配置与激活边界。
@MainActor
protocol PlaybackAudioSessionConfiguring: AnyObject {
    func activatePlayback() throws
}

/// 远程命令所需的最小协调器控制面，避免复制 Task 6 的播放状态机。
@MainActor
struct NowPlayingControls {
    let play: () -> Void
    let pause: () -> Void
    let next: () throws -> Void
    let previous: () throws -> Void
    let seek: (TimeInterval) -> Void
}

/// 维护后台音频、锁屏媒体信息与系统远程命令的完整生命周期。
@MainActor
final class NowPlayingService {
    private let snapshotPublisher: AnyPublisher<PlaybackSnapshot, Never>
    private let commands: any RemoteCommandRegistering
    private let infoCenter: any NowPlayingInfoWriting
    private let audioSession: any PlaybackAudioSessionConfiguring
    private let controls: NowPlayingControls
    private let commandState = RemoteCommandStateCache()
    private var commandTokens = [RemotePlaybackCommand: AnyObject]()
    private var snapshotCancellable: AnyCancellable?
    private var latestSnapshot = PlaybackSnapshot()
    private var isStarted = false
    private var lifecycleGeneration: RemoteCommandGeneration?

    init(
        snapshotPublisher: AnyPublisher<PlaybackSnapshot, Never>,
        commands: any RemoteCommandRegistering,
        infoCenter: any NowPlayingInfoWriting,
        audioSession: any PlaybackAudioSessionConfiguring,
        controls: NowPlayingControls
    ) {
        self.snapshotPublisher = snapshotPublisher
        self.commands = commands
        self.infoCenter = infoCenter
        self.audioSession = audioSession
        self.controls = controls
    }

    /// 激活成功后才建立 target 和订阅；失败时调用方可记录并决定是否重试。
    func start() throws {
        guard !isStarted else { return }
        try audioSession.activatePlayback()

        let registrationGeneration = RemoteCommandGeneration()
        lifecycleGeneration = registrationGeneration
        isStarted = true
        commandState.start(generation: registrationGeneration)
        for command in RemotePlaybackCommand.allCases {
            let commandState = self.commandState
            commandTokens[command] = commands.addTarget(for: command) { [weak self] payload in
                let decision = commandState.decision(
                    for: command,
                    payload: payload,
                    expectedGeneration: registrationGeneration
                )
                guard let generation = decision.actionGeneration else {
                    return decision.status
                }

                if Thread.isMainThread {
                    // iOS 的 MainActor 运行在主线程；仅此已验证分支允许同步返回真实控制结果。
                    return MainActor.assumeIsolated {
                        self?.execute(command, payload: payload, generation: generation)
                            ?? .commandFailed
                    }
                }

                // 后台 handler 绝不等待主线程；缓存已决定返回值，真实动作异步投递。
                Task { @MainActor [weak self] in
                    _ = self?.execute(command, payload: payload, generation: generation)
                }
                return decision.status
            }
        }

        // PlaybackCoordinator 只在 MainActor 发布；这里显式校验这一系统 API 边界。
        snapshotCancellable = snapshotPublisher.sink { [weak self] snapshot in
            MainActor.assumeIsolated {
                self?.consume(snapshot)
            }
        }
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        lifecycleGeneration = nil
        commandState.stop()
        snapshotCancellable?.cancel()
        snapshotCancellable = nil
        for (command, token) in commandTokens {
            commands.removeTarget(token, for: command)
        }
        commandTokens.removeAll()
    }

    isolated deinit {
        stop()
    }

    private func execute(
        _ command: RemotePlaybackCommand,
        payload: RemoteCommandPayload,
        generation: RemoteCommandGeneration
    ) -> MPRemoteCommandHandlerStatus {
        guard isStarted, lifecycleGeneration === generation else { return .commandFailed }

        switch command {
        case .play:
            guard latestSnapshot.track != nil, latestSnapshot.status != .idle else {
                return .noSuchContent
            }
            guard latestSnapshot.status == .paused else {
                return latestSnapshot.status == .playing ? .success : .commandFailed
            }
            controls.play()
            return .success
        case .pause:
            guard latestSnapshot.track != nil, latestSnapshot.status != .idle else {
                return .noSuchContent
            }
            guard latestSnapshot.status == .playing else {
                return latestSnapshot.status == .paused ? .success : .commandFailed
            }
            controls.pause()
            return .success
        case .next:
            guard hasCurrentQueueItem else { return .noSuchContent }
            return runThrowingControl(controls.next)
        case .previous:
            guard hasCurrentQueueItem else { return .noSuchContent }
            return runThrowingControl(controls.previous)
        case .changePlaybackPosition:
            guard case let .position(position) = payload,
                  position.isFinite,
                  position >= 0,
                  latestSnapshot.track != nil,
                  latestSnapshot.status == .playing || latestSnapshot.status == .paused else {
                return .commandFailed
            }
            controls.seek(position)
            return .success
        }
    }

    private var hasCurrentQueueItem: Bool {
        latestSnapshot.track != nil
            && latestSnapshot.status != .idle
            && latestSnapshot.queueIndex != nil
            && latestSnapshot.queueCount > 0
    }

    private func runThrowingControl(_ control: () throws -> Void) -> MPRemoteCommandHandlerStatus {
        do {
            try control()
            return .success
        } catch {
            return .commandFailed
        }
    }

    private func consume(_ snapshot: PlaybackSnapshot) {
        latestSnapshot = snapshot
        commandState.update(
            playbackState: remoteCommandState(for: snapshot.status),
            hasTrack: snapshot.track != nil,
            queueIndex: snapshot.queueIndex,
            queueCount: snapshot.queueCount
        )
        guard snapshot.status != .idle, let track = snapshot.track else {
            infoCenter.nowPlayingInfo = nil
            return
        }

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist,
            MPMediaItemPropertyAlbumTitle: track.album,
            MPMediaItemPropertyPlaybackDuration: max(0, snapshot.duration),
            MPNowPlayingInfoPropertyElapsedPlaybackTime: max(0, snapshot.elapsed),
            MPNowPlayingInfoPropertyPlaybackRate: snapshot.status == .playing ? 1.0 : 0.0
        ]
        if let data = track.artworkData, let image = UIImage(data: data) {
            // MPMediaItemArtwork 持有请求闭包；捕获不可变 UIImage 避免跨线程读取服务状态。
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(
                boundsSize: image.size,
                requestHandler: { _ in image }
            )
        }
        infoCenter.nowPlayingInfo = info
    }

    private func remoteCommandState(for status: PlaybackStatus) -> RemoteCommandPlaybackState {
        switch status {
        case .idle:
            .idle
        case .loading:
            .loading
        case .playing:
            .playing
        case .paused:
            .paused
        case .failed:
            .failed
        }
    }
}

@MainActor
final class SystemRemoteCommandRegister: RemoteCommandRegistering {
    private let center: MPRemoteCommandCenter

    init(center: MPRemoteCommandCenter = .shared()) {
        self.center = center
    }

    func addTarget(
        for command: RemotePlaybackCommand,
        handler: @escaping RemoteCommandHandler
    ) -> AnyObject {
        systemCommand(for: command).addTarget { event in
            let payload: RemoteCommandPayload
            if let positionEvent = event as? MPChangePlaybackPositionCommandEvent {
                payload = .position(positionEvent.positionTime)
            } else {
                payload = .none
            }
            return handler(payload)
        } as AnyObject
    }

    func removeTarget(_ token: AnyObject, for command: RemotePlaybackCommand) {
        systemCommand(for: command).removeTarget(token)
    }

    private func systemCommand(for command: RemotePlaybackCommand) -> MPRemoteCommand {
        switch command {
        case .play:
            center.playCommand
        case .pause:
            center.pauseCommand
        case .next:
            center.nextTrackCommand
        case .previous:
            center.previousTrackCommand
        case .changePlaybackPosition:
            center.changePlaybackPositionCommand
        }
    }

}

extension MPNowPlayingInfoCenter: NowPlayingInfoWriting {}

@MainActor
final class SystemPlaybackAudioSession: PlaybackAudioSessionConfiguring {
    private let session: AVAudioSession

    init(session: AVAudioSession = .sharedInstance()) {
        self.session = session
    }

    func activatePlayback() throws {
        try session.setCategory(.playback)
        try session.setActive(true)
    }
}
