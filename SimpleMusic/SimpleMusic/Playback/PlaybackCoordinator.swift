import Combine
import Foundation

enum PlaybackCoordinatorError: Error {
    case invalidStartIndex
}

/// 统一维护播放队列、活动后端与界面快照；后端切换和所有索引变更只在此发生。
@MainActor
final class PlaybackCoordinator: PlaybackBackendDelegate {
    private let localBackend: any PlaybackBackend
    private let systemBackend: any PlaybackBackend
    private let snapshotSubject = CurrentValueSubject<PlaybackSnapshot, Never>(PlaybackSnapshot())
    private var sourceQueue = [MusicTrack]()
    private var queue = [MusicTrack]()
    private var currentIndex: Int?
    private var playbackMode: PlaybackMode = .list
    private var audioEffectSettings: AudioEffectSettings
    private weak var activeBackend: (any PlaybackBackend)?
    private var activeGeneration: PlaybackGeneration?
    private var nextGenerationRawValue: UInt64 = 0

    var snapshotPublisher: AnyPublisher<PlaybackSnapshot, Never> {
        snapshotSubject.eraseToAnyPublisher()
    }

    init(
        localBackend: any PlaybackBackend,
        systemBackend: any PlaybackBackend,
        initialAudioEffectSettings: AudioEffectSettings? = nil
    ) {
        let resolvedAudioEffectSettings = initialAudioEffectSettings ?? AudioEffectSettings()
        self.localBackend = localBackend
        self.systemBackend = systemBackend
        audioEffectSettings = resolvedAudioEffectSettings
        localBackend.delegate = self
        systemBackend.delegate = self
        localBackend.updateAudioEffect(resolvedAudioEffectSettings)
    }

    func play(queue: [MusicTrack], startAt index: Int) throws {
        guard !queue.isEmpty else {
            stopAndResetQueue()
            return
        }
        guard queue.indices.contains(index) else {
            throw PlaybackCoordinatorError.invalidStartIndex
        }

        sourceQueue = queue
        if playbackMode == .shuffle {
            let currentTrack = queue[index]
            self.queue = [currentTrack] + queue.enumerated()
                .filter { $0.offset != index }
                .map(\.element)
                .shuffled()
            try activate(index: 0)
        } else {
            self.queue = queue
            try activate(index: index)
        }
    }

    /// 随机播放只生成一次完整队列，后续 next/previous 仍沿该固定顺序移动。
    func playShuffled(queue: [MusicTrack]) throws {
        guard !queue.isEmpty else {
            stopAndResetQueue()
            return
        }
        playbackMode = .shuffle
        sourceQueue = queue
        self.queue = queue.shuffled()
        try activate(index: 0)
    }

    func cyclePlaybackMode() {
        playbackMode = playbackMode.next
        reorderQueueForPlaybackMode()
        updateSnapshot {
            $0.playbackMode = playbackMode
            $0.queueIndex = currentIndex
            $0.queueCount = queue.count
            $0.queue = queue
        }
    }

    func selectQueueItem(at index: Int) throws {
        guard queue.indices.contains(index) else {
            throw PlaybackCoordinatorError.invalidStartIndex
        }
        try activate(index: index)
    }

    func updateAudioEffect(_ settings: AudioEffectSettings) {
        audioEffectSettings = settings
        localBackend.updateAudioEffect(settings)
        updateSnapshot { $0.audioEffectSettings = settings }
    }

    func togglePlay() {
        guard let activeBackend else { return }
        switch snapshotSubject.value.status {
        case .playing:
            activeBackend.pause()
            updateSnapshot { $0.status = .paused }
        case .paused:
            activeBackend.play()
            updateSnapshot { $0.status = .playing }
        case .idle, .loading, .failed:
            break
        }
    }

    func seek(to seconds: TimeInterval) {
        guard let activeBackend else { return }
        let elapsed = max(0, seconds)
        activeBackend.seek(to: elapsed)
        updateSnapshot { $0.elapsed = elapsed }
    }

    func previous() throws {
        guard let currentIndex else { return }
        guard currentIndex > queue.startIndex else {
            seek(to: 0)
            return
        }
        try activate(index: currentIndex - 1)
    }

    func next() throws {
        guard let currentIndex else { return }
        let nextIndex = currentIndex + 1
        guard queue.indices.contains(nextIndex) else {
            stopAtQueueEnd()
            return
        }
        try activate(index: nextIndex)
    }

    func playbackBackend(
        _ backend: any PlaybackBackend,
        generation: PlaybackGeneration,
        didUpdateElapsed elapsed: TimeInterval,
        duration: TimeInterval
    ) {
        guard isActive(backend, generation: generation) else { return }
        updateSnapshot {
            $0.elapsed = max(0, elapsed)
            $0.duration = max(0, duration)
        }
    }

    func playbackBackendDidFinish(
        _ backend: any PlaybackBackend,
        generation: PlaybackGeneration
    ) {
        guard isActive(backend, generation: generation) else { return }
        do {
            if playbackMode == .repeatOne, let currentIndex {
                try activate(index: currentIndex)
            } else {
                try next()
            }
        } catch {
            publishFailure(error)
        }
    }

    func playbackBackend(
        _ backend: any PlaybackBackend,
        generation: PlaybackGeneration,
        didFail error: Error
    ) {
        guard isActive(backend, generation: generation) else { return }
        publishFailure(error)
    }

    private func activate(index: Int) throws {
        let track = queue[index]
        let backend = backend(for: track.source)
        let generation = makeGeneration()

        // 跨来源必须先停旧后端，再加载新后端，避免两个系统播放器短暂重叠出声。
        if let activeBackend, activeBackend !== backend {
            activeBackend.stop()
        }
        activeBackend = backend
        activeGeneration = generation
        currentIndex = index
        snapshotSubject.send(PlaybackSnapshot(
            status: .loading,
            track: track,
            elapsed: 0,
            duration: track.duration,
            queueIndex: index,
            queueCount: queue.count,
            playbackMode: playbackMode,
            audioEffectSettings: audioEffectSettings,
            queue: queue
        ))

        do {
            try backend.load(track, generation: generation)
            backend.play()
            updateSnapshot { $0.status = .playing }
        } catch {
            backend.stop()
            publishFailure(error)
            throw error
        }
    }

    private func backend(for source: MusicSource) -> any PlaybackBackend {
        switch source {
        case .downloaded:
            localBackend
        case .system:
            systemBackend
        }
    }

    private func stopAtQueueEnd() {
        activeBackend?.stop()
        activeBackend = nil
        activeGeneration = nil
        currentIndex = nil
        updateSnapshot {
            $0.status = .idle
            $0.elapsed = 0
            $0.queueIndex = nil
        }
    }

    private func stopAndResetQueue() {
        activeBackend?.stop()
        activeBackend = nil
        activeGeneration = nil
        sourceQueue = []
        queue = []
        currentIndex = nil
        snapshotSubject.send(PlaybackSnapshot(
            playbackMode: playbackMode,
            audioEffectSettings: audioEffectSettings
        ))
    }

    private func publishFailure(_ error: Error) {
        updateSnapshot { $0.status = .failed(String(describing: error)) }
    }

    private func updateSnapshot(_ mutation: (inout PlaybackSnapshot) -> Void) {
        var snapshot = snapshotSubject.value
        mutation(&snapshot)
        snapshotSubject.send(snapshot)
    }

    private func isActive(
        _ backend: any PlaybackBackend,
        generation: PlaybackGeneration
    ) -> Bool {
        guard let activeBackend else { return false }
        return activeBackend === backend && activeGeneration == generation
    }

    private func makeGeneration() -> PlaybackGeneration {
        nextGenerationRawValue &+= 1
        return PlaybackGeneration(rawValue: nextGenerationRawValue)
    }

    private func reorderQueueForPlaybackMode() {
        guard let currentIndex, queue.indices.contains(currentIndex) else { return }
        let currentTrack = queue[currentIndex]
        switch playbackMode {
        case .shuffle:
            queue = [currentTrack] + sourceQueue
                .filter { $0.id != currentTrack.id }
                .shuffled()
            self.currentIndex = 0
        case .list, .repeatOne:
            guard queue.map(\.id) != sourceQueue.map(\.id),
                  let restoredIndex = sourceQueue.firstIndex(where: { $0.id == currentTrack.id }) else {
                return
            }
            queue = sourceQueue
            self.currentIndex = restoredIndex
        }
    }
}
