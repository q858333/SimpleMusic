import AVFAudio
import Combine
import MediaPlayer
import UIKit

enum RemotePlaybackCommand: CaseIterable, Hashable, Sendable {
    case play
    case pause
    case next
    case previous
    case changePlaybackPosition
}

enum RemoteCommandPayload: Sendable {
    case none
    case position(TimeInterval)
}

typealias RemoteCommandHandler = @MainActor @Sendable (
    RemoteCommandPayload
) -> MPRemoteCommandHandlerStatus

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
    private var commandTokens = [RemotePlaybackCommand: AnyObject]()
    private var snapshotCancellable: AnyCancellable?
    private var latestSnapshot = PlaybackSnapshot()
    private var isStarted = false

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

        isStarted = true
        for command in RemotePlaybackCommand.allCases {
            commandTokens[command] = commands.addTarget(for: command) { [weak self] payload in
                self?.handle(command, payload: payload) ?? .commandFailed
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
        snapshotCancellable?.cancel()
        snapshotCancellable = nil
        for (command, token) in commandTokens {
            commands.removeTarget(token, for: command)
        }
        commandTokens.removeAll()
        isStarted = false
    }

    isolated deinit {
        stop()
    }

    private func handle(
        _ command: RemotePlaybackCommand,
        payload: RemoteCommandPayload
    ) -> MPRemoteCommandHandlerStatus {
        guard latestSnapshot.track != nil, latestSnapshot.status != .idle else {
            return .noSuchContent
        }

        switch command {
        case .play:
            guard latestSnapshot.status == .paused else {
                return latestSnapshot.status == .playing ? .success : .commandFailed
            }
            controls.play()
            return .success
        case .pause:
            guard latestSnapshot.status == .playing else {
                return latestSnapshot.status == .paused ? .success : .commandFailed
            }
            controls.pause()
            return .success
        case .next:
            return runThrowingControl(controls.next)
        case .previous:
            return runThrowingControl(controls.previous)
        case .changePlaybackPosition:
            guard case let .position(position) = payload,
                  position.isFinite,
                  position >= 0 else {
                return .commandFailed
            }
            controls.seek(position)
            return .success
        }
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
            return Self.runOnMainActor {
                handler(payload)
            }
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

    /// MediaPlayer 不保证回调队列；同步切回主线程才能安全读取 MainActor 播放状态并返回结果。
    private nonisolated static func runOnMainActor<T: Sendable>(
        _ operation: @escaping @MainActor @Sendable () -> T
    ) -> T {
        if Thread.isMainThread {
            return MainActor.assumeIsolated(operation)
        }
        return DispatchQueue.main.sync {
            MainActor.assumeIsolated(operation)
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
