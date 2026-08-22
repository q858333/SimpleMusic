import AVFoundation
import Foundation

nonisolated private enum LocalLeasePreparationResult: @unchecked Sendable {
    case success(PlaybackFileLease)
    case failure(Error)
}

/// 混响播放驱动只负责单个本地文件；generation 与 lease 生命周期仍由后端维护。
@MainActor
protocol ReverbAudioPlaying: AnyObject {
    var elapsed: TimeInterval { get }
    var duration: TimeInterval { get }
    var onFinish: (() -> Void)? { get set }
    func load(url: URL, startingAt seconds: TimeInterval, settings: AudioEffectSettings) throws
    func update(settings: AudioEffectSettings)
    func play()
    func pause()
    func stop()
    func seek(to seconds: TimeInterval)
}

/// 通过系统 AVAudioEngine 把下载文件接入 AVAudioUnitReverb，不处理系统音乐库输出。
@MainActor
final class SystemReverbAudioPlayer: ReverbAudioPlaying {
    var onFinish: (() -> Void)?

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let reverb = AVAudioUnitReverb()
    private var file: AVAudioFile?
    private var startFrame: AVAudioFramePosition = 0
    private var scheduleToken: UInt64 = 0

    var duration: TimeInterval {
        guard let file else { return 0 }
        return Double(file.length) / file.processingFormat.sampleRate
    }

    var elapsed: TimeInterval {
        guard let file else { return 0 }
        let sampleRate = file.processingFormat.sampleRate
        guard sampleRate > 0,
              let renderTime = playerNode.lastRenderTime,
              let playerTime = playerNode.playerTime(forNodeTime: renderTime) else {
            return Double(startFrame) / max(1, sampleRate)
        }
        return min(
            duration,
            Double(startFrame + playerTime.sampleTime) / sampleRate
        )
    }

    init() {
        engine.attach(playerNode)
        engine.attach(reverb)
    }

    isolated deinit {
        stop()
        engine.stop()
    }

    func load(url: URL, startingAt seconds: TimeInterval, settings: AudioEffectSettings) throws {
        stop()
        let file = try AVAudioFile(forReading: url)
        self.file = file
        engine.disconnectNodeOutput(playerNode)
        engine.disconnectNodeOutput(reverb)
        engine.connect(playerNode, to: reverb, format: file.processingFormat)
        engine.connect(reverb, to: engine.mainMixerNode, format: nil)
        update(settings: settings)
        engine.prepare()
        if !engine.isRunning {
            try engine.start()
        }
        schedule(from: seconds)
    }

    func update(settings: AudioEffectSettings) {
        reverb.loadFactoryPreset(settings.preset.avPreset)
        reverb.wetDryMix = settings.preset == .off ? 0 : settings.wetDryMix
    }

    func play() {
        guard file != nil else { return }
        if !engine.isRunning {
            try? engine.start()
        }
        playerNode.play()
    }

    func pause() {
        playerNode.pause()
    }

    func stop() {
        scheduleToken &+= 1
        playerNode.stop()
        engine.stop()
        file = nil
        startFrame = 0
    }

    func seek(to seconds: TimeInterval) {
        guard file != nil else { return }
        let wasPlaying = playerNode.isPlaying
        playerNode.stop()
        schedule(from: seconds)
        if wasPlaying {
            playerNode.play()
        }
    }

    private func schedule(from seconds: TimeInterval) {
        guard let file else { return }
        scheduleToken &+= 1
        let token = scheduleToken
        let sampleRate = max(1, file.processingFormat.sampleRate)
        let requestedFrame = AVAudioFramePosition(max(0, seconds) * sampleRate)
        startFrame = min(max(0, requestedFrame), file.length)
        let remainingFrames = max(0, file.length - startFrame)
        let frameCount = AVAudioFrameCount(min(
            AVAudioFramePosition(AVAudioFrameCount.max),
            remainingFrames
        ))
        guard frameCount > 0 else {
            onFinish?()
            return
        }
        playerNode.scheduleSegment(
            file,
            startingFrame: startFrame,
            frameCount: frameCount,
            at: nil,
            completionCallbackType: .dataPlayedBack
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.scheduleToken == token else { return }
                self.onFinish?()
            }
        }
    }
}

private extension AudioEffectPreset {
    var avPreset: AVAudioUnitReverbPreset {
        switch self {
        case .off, .smallRoom: return .smallRoom
        case .mediumRoom: return .mediumRoom
        case .largeRoom: return .largeRoom
        case .mediumHall: return .mediumHall
        case .largeHall: return .largeHall
        case .cathedral: return .cathedral
        case .plate: return .plate
        }
    }
}

/// AVPlayer API 可跨队列控制；holder 在非隔离析构中幂等停止并移除 time observer。
nonisolated private final class LocalPlayerLifetime: @unchecked Sendable {
    let player: AVPlayer
    private let lock = NSLock()
    private var timeObserver: Any?
    private var progressTimer: Timer?
    private var isTornDown = false

    init(player: AVPlayer) {
        self.player = player
    }

    func setTimeObserver(_ timeObserver: Any) {
        lock.lock()
        self.timeObserver = timeObserver
        lock.unlock()
    }

    func setProgressTimer(_ timer: Timer) {
        lock.lock()
        progressTimer = timer
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
        let progressTimer = self.progressTimer
        self.timeObserver = nil
        self.progressTimer = nil
        lock.unlock()

        player.pause()
        player.replaceCurrentItem(with: nil)
        progressTimer?.invalidate()
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
        var item: AVPlayerItem?
        let generation: PlaybackGeneration
        let lease: PlaybackFileLease
    }

    let kind = PlaybackBackendKind.local
    weak var delegate: (any PlaybackBackendDelegate)?

    private let leaseProvider: LeaseProvider
    private let player: AVPlayer
    private let playerLifetime: LocalPlayerLifetime
    private let reverbPlayer: any ReverbAudioPlaying
    private let observationBag: NotificationObservationBag
    private var activeItem: ActiveItem?
    private var requestedGeneration: PlaybackGeneration?
    private var pendingPlay = false
    private var isPlayingRequested = false
    private var isReverbTransportActive = false
    private var audioEffectSettings = AudioEffectSettings()
    private var preparationTask: Task<Void, Never>?

    init(
        fileStore: DownloadFileStore? = nil,
        player: AVPlayer = AVPlayer(),
        notificationCenter: NotificationCenter = .default,
        leaseProvider: LeaseProvider? = nil,
        reverbPlayer: (any ReverbAudioPlaying)? = nil
    ) {
        self.leaseProvider = leaseProvider ?? { fileName in
            guard let fileStore else { throw DownloadFileStoreError.fileNotFound }
            return try fileStore.playbackLease(for: fileName)
        }
        self.player = player
        self.reverbPlayer = reverbPlayer ?? SystemReverbAudioPlayer()
        playerLifetime = LocalPlayerLifetime(player: player)
        observationBag = NotificationObservationBag(notificationCenter: notificationCenter)
        super.init()

        self.reverbPlayer.onFinish = { [weak self] in
            self?.reverbDidFinish()
        }

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
        let progressTimer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isReverbTransportActive else { return }
                self.publishProgress()
            }
        }
        RunLoop.main.add(progressTimer, forMode: .common)
        playerLifetime.setProgressTimer(progressTimer)
    }

    func load(_ track: MusicTrack, generation: PlaybackGeneration) throws {
        guard case let .downloaded(fileName) = track.source else {
            throw PlaybackBackendError.incompatibleSource
        }

        cancelPreparation()
        releaseActiveItem()
        requestedGeneration = generation
        pendingPlay = false
        isPlayingRequested = false

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
            isPlayingRequested = true
            if isReverbTransportActive {
                reverbPlayer.play()
            } else {
                player.play()
            }
        } else if requestedGeneration != nil {
            pendingPlay = true
        }
    }

    func pause() {
        pendingPlay = false
        isPlayingRequested = false
        if isReverbTransportActive {
            reverbPlayer.pause()
        } else {
            player.pause()
        }
    }

    func stop() {
        cancelPreparation()
        isPlayingRequested = false
        player.pause()
        reverbPlayer.stop()
        releaseActiveItem()
    }

    func seek(to seconds: TimeInterval) {
        if isReverbTransportActive {
            reverbPlayer.seek(to: seconds)
        } else {
            player.seek(to: CMTime(seconds: max(0, seconds), preferredTimescale: 600))
        }
    }

    func updateAudioEffect(_ settings: AudioEffectSettings) {
        let previouslyUsedReverb = isReverbTransportActive
        audioEffectSettings = settings
        reverbPlayer.update(settings: settings)
        let wantsReverb = settings.preset != .off
        guard activeItem != nil, previouslyUsedReverb != wantsReverb else { return }
        if wantsReverb {
            switchToReverbPlayback()
        } else {
            switchToPlayerPlayback()
        }
    }

    private func itemDidFinish(_ notification: Notification) {
        guard let activeItem,
              let item = activeItem.item,
              notification.object as AnyObject? === item else { return }
        delegate?.playbackBackendDidFinish(self, generation: activeItem.generation)
    }

    private func itemDidFail(_ notification: Notification) {
        guard let activeItem,
              let item = activeItem.item,
              notification.object as AnyObject? === item else { return }
        let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            ?? PlaybackBackendError.playbackFailed
        delegate?.playbackBackend(self, generation: activeItem.generation, didFail: error)
    }

    private func publishProgress() {
        guard let activeItem else { return }
        let elapsed: TimeInterval
        let duration: TimeInterval
        if isReverbTransportActive {
            elapsed = Self.finiteSeconds(reverbPlayer.elapsed)
            duration = Self.finiteSeconds(reverbPlayer.duration)
        } else {
            guard let item = activeItem.item, player.currentItem === item else { return }
            elapsed = Self.finiteSeconds(player.currentTime().seconds)
            duration = Self.finiteSeconds(item.duration.seconds)
        }
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
        reverbPlayer.stop()
        isReverbTransportActive = false
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
            if audioEffectSettings.preset != .off {
                do {
                    try reverbPlayer.load(
                        url: lease.fileURL,
                        startingAt: 0,
                        settings: audioEffectSettings
                    )
                    isReverbTransportActive = true
                    activeItem = ActiveItem(item: nil, generation: generation, lease: lease)
                } catch {
                    // 可选音效失败时保留用户设置，当前歌曲自动回退原始播放。
                    isReverbTransportActive = false
                    let item = AVPlayerItem(url: lease.fileURL)
                    activeItem = ActiveItem(item: item, generation: generation, lease: lease)
                    player.replaceCurrentItem(with: item)
                    NSLog("混响引擎启动失败，继续原始播放：%@", String(describing: error))
                }
            } else {
                isReverbTransportActive = false
                let item = AVPlayerItem(url: lease.fileURL)
                activeItem = ActiveItem(item: item, generation: generation, lease: lease)
                player.replaceCurrentItem(with: item)
            }
            if pendingPlay {
                pendingPlay = false
                isPlayingRequested = true
                if isReverbTransportActive {
                    reverbPlayer.play()
                } else {
                    player.play()
                }
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

    private func switchToReverbPlayback() {
        guard var activeItem, let item = activeItem.item else { return }
        let elapsed = Self.finiteSeconds(player.currentTime().seconds)
        player.pause()
        player.replaceCurrentItem(with: nil)
        do {
            try reverbPlayer.load(
                url: activeItem.lease.fileURL,
                startingAt: elapsed,
                settings: audioEffectSettings
            )
            activeItem.item = nil
            self.activeItem = activeItem
            isReverbTransportActive = true
            if isPlayingRequested {
                reverbPlayer.play()
            }
        } catch {
            // 音效引擎不可用时继续原始播放，不让可选效果中断歌曲。
            player.replaceCurrentItem(with: item)
            player.seek(to: CMTime(seconds: elapsed, preferredTimescale: 600))
            if isPlayingRequested {
                player.play()
            }
            isReverbTransportActive = false
            NSLog("混响引擎启动失败，继续原始播放：%@", String(describing: error))
        }
    }

    private func switchToPlayerPlayback() {
        guard var activeItem, activeItem.item == nil else { return }
        let elapsed = Self.finiteSeconds(reverbPlayer.elapsed)
        reverbPlayer.stop()
        isReverbTransportActive = false
        let item = AVPlayerItem(url: activeItem.lease.fileURL)
        activeItem.item = item
        self.activeItem = activeItem
        player.replaceCurrentItem(with: item)
        player.seek(to: CMTime(seconds: elapsed, preferredTimescale: 600))
        if isPlayingRequested {
            player.play()
        }
    }

    private func reverbDidFinish() {
        guard isReverbTransportActive, let activeItem else { return }
        delegate?.playbackBackendDidFinish(self, generation: activeItem.generation)
    }

    private static func finiteSeconds(_ seconds: TimeInterval) -> TimeInterval {
        seconds.isFinite ? max(0, seconds) : 0
    }
}
